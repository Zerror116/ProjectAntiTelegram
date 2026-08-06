#!/usr/bin/env node

const { execFileSync } = require("child_process");

function parseArgs(argv) {
  const args = {
    workflow: process.env.GITHUB_ACTIONS_WORKFLOW || "Security CI",
    branch: process.env.GITHUB_ACTIONS_BRANCH || "",
    repo: process.env.GITHUB_REPOSITORY || "",
    requireCurrentHead:
      String(process.env.GITHUB_ACTIONS_REQUIRE_CURRENT_HEAD || "0").trim() ===
      "1",
  };
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i];
    if (value === "--workflow") args.workflow = argv[++i] || args.workflow;
    if (value === "--branch") args.branch = argv[++i] || args.branch;
    if (value === "--repo") args.repo = argv[++i] || args.repo;
    if (value === "--require-current-head") args.requireCurrentHead = true;
  }
  return args;
}

function run(command, args, options = {}) {
  try {
    return execFileSync(command, args, {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "pipe"],
      maxBuffer: 20 * 1024 * 1024,
      ...options,
    }).trim();
  } catch (err) {
    const stderr = String(err?.stderr || "").trim();
    const stdout = String(err?.stdout || "").trim();
    const reason = stderr || stdout || String(err?.message || err);
    throw new Error(`${command} ${args.join(" ")} failed: ${reason}`);
  }
}

function parseJson(raw, fallback) {
  try {
    return JSON.parse(raw);
  } catch (_) {
    return fallback;
  }
}

function detectRepoFromGitRemote() {
  const remote = run("git", ["config", "--get", "remote.origin.url"]);
  const sshMatch = remote.match(/github\.com[:/]([^/\s]+)\/([^/\s.]+)(?:\.git)?$/i);
  if (sshMatch) return `${sshMatch[1]}/${sshMatch[2]}`;
  const urlMatch = remote.match(/github\.com\/([^/\s]+)\/([^/\s.]+)(?:\.git)?$/i);
  if (urlMatch) return `${urlMatch[1]}/${urlMatch[2]}`;
  throw new Error(`Could not detect GitHub repo from origin URL: ${remote}`);
}

function currentBranch() {
  const branch = run("git", ["rev-parse", "--abbrev-ref", "HEAD"]);
  if (!branch || branch === "HEAD") return "master";
  return branch;
}

function currentHeadSha() {
  return run("git", ["rev-parse", "HEAD"]);
}

function githubApi(endpointOrUrl) {
  let endpoint = String(endpointOrUrl || "").trim();
  endpoint = endpoint.replace(/^https:\/\/api\.github\.com\//, "");
  if (!endpoint) throw new Error("Empty GitHub API endpoint");
  return parseJson(run("gh", ["api", endpoint]), null);
}

function loadLatestWorkflowRun({ repo, workflow, branch }) {
  const rows = parseJson(
    run("gh", [
      "run",
      "list",
      "--repo",
      repo,
      "--workflow",
      workflow,
      "--branch",
      branch,
      "--limit",
      "1",
      "--json",
      "databaseId,displayTitle,headSha,status,conclusion,url,workflowName,createdAt",
    ]),
    [],
  );
  if (!Array.isArray(rows) || rows.length === 0) {
    throw new Error(`No GitHub Actions runs found for workflow="${workflow}" branch="${branch}"`);
  }
  return rows[0];
}

function loadRunJobs(repo, runId) {
  const payload = githubApi(`repos/${repo}/actions/runs/${runId}/jobs`);
  return Array.isArray(payload?.jobs) ? payload.jobs : [];
}

function loadJobAnnotations(job) {
  if (!job?.check_run_url) return [];
  const annotations = githubApi(`${job.check_run_url}/annotations`);
  return Array.isArray(annotations) ? annotations : [];
}

function simplifyAnnotation(annotation) {
  return {
    level: annotation.annotation_level || null,
    path: annotation.path || null,
    message: annotation.message || null,
  };
}

function fail(summary) {
  console.error(JSON.stringify(summary, null, 2));
  process.exit(1);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const repo = args.repo || detectRepoFromGitRemote();
  const branch = args.branch || currentBranch();
  const headSha = currentHeadSha();
  const runInfo = loadLatestWorkflowRun({
    repo,
    workflow: args.workflow,
    branch,
  });
  const jobs = loadRunJobs(repo, runInfo.databaseId);
  const simplifiedJobs = jobs.map((job) => {
    const annotations =
      Array.isArray(job.steps) && job.steps.length > 0
        ? []
        : loadJobAnnotations(job).map(simplifyAnnotation);
    return {
      name: job.name || "",
      status: job.status || "",
      conclusion: job.conclusion || "",
      runner_name: job.runner_name || "",
      step_count: Array.isArray(job.steps) ? job.steps.length : 0,
      annotations,
    };
  });

  const summary = {
    ok: true,
    repo,
    workflow: args.workflow,
    branch,
    required_head_sha: args.requireCurrentHead ? headSha : null,
    run: {
      id: runInfo.databaseId,
      title: runInfo.displayTitle,
      head_sha: runInfo.headSha,
      status: runInfo.status,
      conclusion: runInfo.conclusion,
      url: runInfo.url,
      created_at: runInfo.createdAt,
    },
    jobs: simplifiedJobs,
  };

  if (args.requireCurrentHead && runInfo.headSha !== headSha) {
    summary.ok = false;
    summary.error = "Latest GitHub Actions run does not match current HEAD";
    fail(summary);
  }

  const emptyStepFailures = simplifiedJobs.filter(
    (job) =>
      job.conclusion === "failure" &&
      job.step_count === 0 &&
      job.annotations.length > 0,
  );
  if (emptyStepFailures.length > 0) {
    summary.ok = false;
    summary.error =
      emptyStepFailures.some((job) =>
        job.annotations.some((annotation) =>
          /billing issue/i.test(String(annotation.message || "")),
        ),
      )
        ? "GitHub Actions jobs did not start because the account is locked due to a billing issue"
        : "GitHub Actions jobs failed before any workflow step started";
    fail(summary);
  }

  if (runInfo.status !== "completed" || runInfo.conclusion !== "success") {
    summary.ok = false;
    summary.error = "Latest GitHub Actions run is not successful";
    fail(summary);
  }

  console.log(JSON.stringify(summary, null, 2));
}

main();
