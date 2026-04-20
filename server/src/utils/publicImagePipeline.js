const fs = require('fs');
const path = require('path');
const sharp = require('sharp');
const { uploadsPath } = require('./storagePaths');
const { sha256File } = require('./chatMediaPipeline');
const { canonicalUploadPathFromAbsolute } = require('./mediaAssets');

const IMAGE_PROFILE_BY_KIND = {
  products: {
    maxOriginalWidth: 2400,
    thumbWidth: 240,
    cardWidth: 960,
    detailWidth: 1600,
  },
  claims: {
    maxOriginalWidth: 2200,
    thumbWidth: 240,
    cardWidth: 900,
    detailWidth: 1400,
  },
  users: {
    maxOriginalWidth: 1400,
    thumbWidth: 160,
    cardWidth: 320,
    detailWidth: 768,
  },
  channels: {
    maxOriginalWidth: 1400,
    thumbWidth: 160,
    cardWidth: 512,
    detailWidth: 1024,
  },
};

function cleanString(rawValue) {
  return String(rawValue || '').trim();
}

function ensureDir(targetPath) {
  fs.mkdirSync(targetPath, { recursive: true });
}

async function describeImage(filePath) {
  const absolutePath = path.resolve(filePath);
  const image = sharp(absolutePath, { animated: false, limitInputPixels: false }).rotate();
  const metadata = await image.metadata();
  const stat = await fs.promises.stat(absolutePath);
  const checksum = await sha256File(absolutePath);
  return {
    image,
    metadata,
    byteSize: stat.size,
    checksum,
    mimeType:
      metadata.format === 'jpeg'
        ? 'image/jpeg'
        : metadata.format === 'png'
        ? 'image/png'
        : metadata.format === 'webp'
        ? 'image/webp'
        : metadata.format === 'gif'
        ? 'image/gif'
        : metadata.format === 'avif'
        ? 'image/avif'
        : metadata.format
        ? `image/${metadata.format}`
        : 'application/octet-stream',
  };
}

async function writeVariant(sourcePath, outputPath, width, { format = 'webp', quality = 82 } = {}) {
  ensureDir(path.dirname(outputPath));
  let pipeline = sharp(sourcePath, { animated: false, limitInputPixels: false })
    .rotate()
    .resize({ width, fit: 'inside', withoutEnlargement: true });

  if (format === 'webp') {
    pipeline = pipeline.webp({ quality, effort: 4 });
  } else if (format === 'jpeg') {
    pipeline = pipeline.jpeg({ quality, mozjpeg: true });
  } else {
    pipeline = pipeline.png({ compressionLevel: 9 });
  }

  await pipeline.toFile(outputPath);
  const metadata = await sharp(outputPath).metadata();
  const stat = await fs.promises.stat(outputPath);
  return {
    width: metadata.width || null,
    height: metadata.height || null,
    byte_size: stat.size,
    mime_type: format === 'jpeg' ? 'image/jpeg' : format === 'webp' ? 'image/webp' : 'image/png',
  };
}

async function ensurePublicImageVariants({ publicKind, sourcePath }) {
  const kind = cleanString(publicKind).toLowerCase();
  const profile = IMAGE_PROFILE_BY_KIND[kind];
  if (!profile) {
    throw new Error(`Unsupported public image kind: ${kind}`);
  }

  const absoluteSourcePath = path.resolve(sourcePath);
  const canonicalOriginalPath = canonicalUploadPathFromAbsolute(absoluteSourcePath);
  if (!canonicalOriginalPath) {
    throw new Error(`Image is outside uploads root: ${sourcePath}`);
  }

  const { metadata, byteSize, checksum, mimeType } = await describeImage(absoluteSourcePath);
  const sourceFilename = path.basename(absoluteSourcePath);
  const baseName = sourceFilename.replace(path.extname(sourceFilename), '');
  const variantsDir = uploadsPath(kind, 'variants');
  ensureDir(variantsDir);

  const thumbPath = path.join(variantsDir, `${baseName}--thumb.webp`);
  const cardPath = path.join(variantsDir, `${baseName}--card.webp`);
  const detailPath = path.join(variantsDir, `${baseName}--detail.jpg`);

  const thumb = await writeVariant(absoluteSourcePath, thumbPath, profile.thumbWidth, {
    format: 'webp',
    quality: 76,
  });
  const card = await writeVariant(absoluteSourcePath, cardPath, profile.cardWidth, {
    format: 'webp',
    quality: 80,
  });
  const detail = await writeVariant(absoluteSourcePath, detailPath, profile.detailWidth, {
    format: 'jpeg',
    quality: 84,
  });

  return {
    original: {
      path: canonicalOriginalPath,
      width: metadata.width || null,
      height: metadata.height || null,
      byte_size: byteSize,
      mime_type: mimeType,
      checksum_sha256: checksum,
    },
    variants: {
      thumb: {
        path: canonicalUploadPathFromAbsolute(thumbPath),
        ...thumb,
      },
      card: {
        path: canonicalUploadPathFromAbsolute(cardPath),
        ...card,
      },
      detail: {
        path: canonicalUploadPathFromAbsolute(detailPath),
        ...detail,
      },
    },
  };
}

module.exports = {
  ensurePublicImageVariants,
};
