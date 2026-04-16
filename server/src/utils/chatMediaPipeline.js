const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const FFMPEG_BIN = process.env.FFMPEG_BIN || 'ffmpeg';
const FFPROBE_BIN = process.env.FFPROBE_BIN || 'ffprobe';

function runCommand(bin, args, { captureStdout = true } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, {
      stdio: ['ignore', captureStdout ? 'pipe' : 'ignore', 'pipe'],
    });
    const stdoutChunks = [];
    const stderrChunks = [];
    if (captureStdout) {
      child.stdout.on('data', (chunk) => stdoutChunks.push(chunk));
    }
    child.stderr.on('data', (chunk) => stderrChunks.push(chunk));
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) {
        resolve({
          stdout: captureStdout ? Buffer.concat(stdoutChunks) : Buffer.alloc(0),
          stderr: Buffer.concat(stderrChunks).toString('utf8'),
        });
        return;
      }
      const error = new Error(
        `${bin} exited with code ${code}: ${Buffer.concat(stderrChunks).toString('utf8')}`,
      );
      error.code = 'MEDIA_PIPELINE_COMMAND_FAILED';
      reject(error);
    });
  });
}

async function sha256File(filePath) {
  return new Promise((resolve, reject) => {
    const hash = crypto.createHash('sha256');
    const stream = fs.createReadStream(filePath);
    stream.on('error', reject);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve(hash.digest('hex')));
  });
}

async function ffprobeJson(filePath) {
  const { stdout } = await runCommand(FFPROBE_BIN, [
    '-v',
    'error',
    '-show_entries',
    'format=duration:stream=index,codec_type,width,height,duration',
    '-of',
    'json',
    filePath,
  ]);
  try {
    return JSON.parse(stdout.toString('utf8'));
  } catch (_) {
    return {};
  }
}

function pickStream(info, codecType) {
  const streams = Array.isArray(info?.streams) ? info.streams : [];
  return streams.find((stream) => String(stream?.codec_type || '') === codecType) || null;
}

function parsePositiveInt(raw) {
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) return null;
  return Math.round(value);
}

function parsePositiveMs(rawSeconds) {
  const value = Number(rawSeconds);
  if (!Number.isFinite(value) || value <= 0) return null;
  return Math.round(value * 1000);
}

async function buildVideoPoster({ filePath, outputDir, filenamePrefix }) {
  fs.mkdirSync(outputDir, { recursive: true });
  const fileName = `${filenamePrefix}-poster.jpg`;
  const outputPath = path.join(outputDir, fileName);
  await runCommand(FFMPEG_BIN, [
    '-y',
    '-ss',
    '00:00:00.200',
    '-i',
    filePath,
    '-frames:v',
    '1',
    '-q:v',
    '3',
    outputPath,
  ], { captureStdout: false });
  return outputPath;
}

async function buildWaveformPeaks(filePath, bucketCount = 48) {
  const { stdout } = await runCommand(FFMPEG_BIN, [
    '-i',
    filePath,
    '-vn',
    '-ac',
    '1',
    '-ar',
    '8000',
    '-f',
    's16le',
    'pipe:1',
  ]);
  if (!stdout || stdout.length < 2) return [];
  const sampleCount = Math.floor(stdout.length / 2);
  if (sampleCount <= 0) return [];
  const perBucket = Math.max(1, Math.floor(sampleCount / bucketCount));
  const peaks = [];
  for (let bucket = 0; bucket < bucketCount; bucket += 1) {
    const start = bucket * perBucket;
    const end = bucket === bucketCount - 1 ? sampleCount : Math.min(sampleCount, start + perBucket);
    let max = 0;
    for (let index = start; index < end; index += 1) {
      const sample = stdout.readInt16LE(index * 2);
      const normalized = Math.abs(sample) / 32768;
      if (normalized > max) max = normalized;
    }
    peaks.push(Number(max.toFixed(4)));
  }
  return peaks;
}

function fileUrlFromPath(req, filePath, uploadsRoot) {
  const relative = path.relative(uploadsRoot, filePath).split(path.sep).join('/');
  return `${req.protocol}://${req.get('host')}/uploads/${relative}`;
}

async function processAttachmentFile({
  req,
  attachmentType,
  filePath,
  uploadsRoot,
  previewOutputDir = null,
  previewPrefix = null,
}) {
  const absolutePath = path.resolve(filePath);
  const stat = await fs.promises.stat(absolutePath);
  const checksum = await sha256File(absolutePath);
  const probe = await ffprobeJson(absolutePath);
  const videoStream = pickStream(probe, 'video');
  const audioStream = pickStream(probe, 'audio');
  const formatDurationMs = parsePositiveMs(probe?.format?.duration);
  const width = parsePositiveInt(videoStream?.width);
  const height = parsePositiveInt(videoStream?.height);
  const durationMs =
    parsePositiveMs(videoStream?.duration) ||
    parsePositiveMs(audioStream?.duration) ||
    formatDurationMs;

  const result = {
    file_size: stat.size,
    checksum_sha256: checksum,
    width,
    height,
    duration_ms: durationMs,
    processing_state: 'ready',
    preview_image_path: null,
    preview_image_url: null,
    preview_width: null,
    preview_height: null,
    waveform_peaks: [],
    extra_meta: {},
  };

  if ((attachmentType === 'video' || attachmentType === 'image') && width && height) {
    result.preview_width = width;
    result.preview_height = height;
  }

  if (attachmentType === 'video' && previewOutputDir && previewPrefix) {
    try {
      const posterPath = await buildVideoPoster({
        filePath: absolutePath,
        outputDir: previewOutputDir,
        filenamePrefix: previewPrefix,
      });
      result.preview_image_path = posterPath;
      result.preview_image_url = fileUrlFromPath(req, posterPath, uploadsRoot);
      const posterProbe = await ffprobeJson(posterPath);
      const posterStream = pickStream(posterProbe, 'video');
      result.preview_width = parsePositiveInt(posterStream?.width) || result.preview_width;
      result.preview_height = parsePositiveInt(posterStream?.height) || result.preview_height;
    } catch (err) {
      result.extra_meta.poster_error = String(err?.message || err);
    }
  }

  if (attachmentType === 'voice') {
    try {
      result.waveform_peaks = await buildWaveformPeaks(absolutePath);
    } catch (err) {
      result.extra_meta.waveform_error = String(err?.message || err);
      result.waveform_peaks = [];
    }
  }

  return result;
}

module.exports = {
  sha256File,
  ffprobeJson,
  processAttachmentFile,
};
