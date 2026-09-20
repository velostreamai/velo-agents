#!/usr/bin/env node
/**
 * SPIKE — a third worker runtime, on the Vercel AI SDK.
 *
 * WHY a third one exists, when #2088 already chose openai-agents:
 *
 * Nothing measured on #2075 moved tool selection reliably. Prompt position,
 * tool registration and a forced opening call all failed to survive
 * replication — bash counts ran 0 to 8 on identical conditions, so any claim
 * of "this nudges the model toward zg" is unprovable at the sample sizes we
 * can afford.
 *
 * This SDK offers something the others do not: `prepareStep` can set
 * `activeTools` PER STEP, removing a tool from the model's visible set rather
 * than merely biasing against it. If `bash` is not active during a discovery
 * step, bash calls in that step are zero BY CONSTRUCTION — no statistics
 * required. That is the only route out of the measurement dead end, and it is
 * the sole question this spike exists to answer.
 *
 * `openai-agents` has `tool_choice` (first call only, then reset) and no
 * equivalent of per-step tool gating.
 *
 * CONTRACT — this is the load-bearing part. `velo-record` parses:
 *     sdk result status=<s> turns=<n>
 *     TOTALS ... leaked_tool_calls= input_tokens= output_tokens=
 *               cached_tokens= read_only= cost_usd= usage_source=
 * and detects timeouts via /exceeded [0-9.]+s|timeout after_seconds/.
 * `velo-status` names a worker from its process argv. Emit the same lines the
 * other two runners emit, or every downstream consumer silently reads nothing
 * — which is exactly the class of silent failure this tooling exists to stop.
 */
import { readFileSync } from "node:fs";
import { appendFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { createRequire } from "node:module";

const require_ = createRequire(path.join(process.env.HOME, ".agents/node/"));
const { ToolLoopAgent, tool, stepCountIs } = require_("ai");
const { createOpenRouter } = require_("@openrouter/ai-sdk-provider");
const { z } = require_("zod");

// ---- args: identical surface to the other two runners -----------------------
const argv = process.argv.slice(2);
const arg = (n, d = null) => {
  const i = argv.indexOf(`--${n}`);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : d;
};
const flag = (n) => argv.includes(`--${n}`);

const MODEL = arg("model");
const POLICY = arg("policy");
const TASK = arg("task");
const CWD = arg("cwd");
const MAX_TURNS = parseInt(arg("max-turns", "100"), 10);
const PROMPT_TIMEOUT = parseFloat(arg("prompt-timeout", "2400"));
const LOG_FILE = arg("log-file");
const MAX_BUDGET = arg("max-budget-usd") ? parseFloat(arg("max-budget-usd")) : null;
const NO_FORCE = flag("no-force-first-tool");
const GATE_DISCOVERY = flag("gate-discovery-step");

if (!MODEL || !POLICY || !TASK || !CWD) {
  console.error("usage: velo-vercel-runner.mjs --model M --policy P --task T --cwd D [...]");
  process.exit(2);
}

const started = Date.now();
const stamp = () => new Date().toISOString().replace(/\.\d{3}Z$/, ".000Z");
function emit(line) {
  const s = `${stamp()} ${line}`;
  if (LOG_FILE) appendFileSync(LOG_FILE, s + "\n");
  else process.stderr.write(s + "\n");
}

// ---- tools: same names and semantics as velo_oai_tools.py -------------------
// Same NAMES matter as much as same behaviour: the log analysis, the policy
// text and velo-record all refer to these by name.
const run = (cmd, args, timeoutMs = 60000) => {
  const r = spawnSync(cmd, args, { cwd: CWD, encoding: "utf8", timeout: timeoutMs,
                                   maxBuffer: 8 * 1024 * 1024 });
  return { rc: r.status ?? 1, out: r.stdout ?? "", err: r.stderr ?? (r.error?.message ?? "") };
};
const cap = (s, n = 24000) =>
  s.length <= n ? s : s.slice(0, n) + `\n…[truncated ${s.length - n} chars]`;

const ZG = path.join(process.env.HOME, ".agents/bin/zg");

const tools = {
  zg_query: tool({
    description:
      "Semantic code search over a pre-built index. Ask in PLAIN ENGLISH what you " +
      "are looking for. Returns ranked hits with file, line range and the ENCLOSING " +
      "SYMBOL NAME AND SCOPE. Use this FIRST when you do not yet know the symbol name.",
    inputSchema: z.object({ question: z.string() }),
    execute: async ({ question }) => {
      const { rc, out, err } = run(ZG, ["query", question], 90000);
      if (rc !== 0) {
        if (/WORKSPACE_INDEX_NOT_FOUND|No zvec-grep index/.test(err))
          return "No discovery index exists for this workspace. Use grep and glob_files instead. Do not run `zg index` — that is the dispatcher's job.";
        return `zg query failed (exit ${rc}): ${err.trim() || "no detail"}`;
      }
      return out.trim() ? cap(out.trim()) : "No hits. The index IS present and the query ran — try different wording.";
    },
  }),
  ast_grep: tool({
    description:
      "STRUCTURAL search/replace over Rust syntax. REQUIRED by the policy for any " +
      "rename, signature change, match-arm change or trait change touching 2+ files. " +
      "grep matches text; this matches SYNTAX. Call first WITHOUT rewrite to see the " +
      "match count — a pattern matching 0 is wrong. Meta-vars: $X one node, $$$ARGS a list.",
    inputSchema: z.object({
      pattern: z.string(), path: z.string().default("src/"),
      rewrite: z.string().default(""), lang: z.string().default("rust"),
      apply: z.boolean().default(false),
    }),
    execute: async ({ pattern, path: p, rewrite, lang, apply }) => {
      const a = ["run", "--pattern", pattern, "--lang", lang];
      if (rewrite) a.push("--rewrite", rewrite);
      if (apply) a.push("-U");
      a.push(p);
      const { rc, out, err } = run("ast-grep", a, 120000);
      // rc=1 is "no matches", like grep. Only rc>=2 is a real failure.
      if (rc >= 2 || (rc !== 0 && err.trim()))
        return `ast-grep failed (rc=${rc}): ${err.trim() || out.trim()}`;
      if (rc === 1 || !out.trim())
        return "0 matches — the PATTERN is wrong, not the codebase. Vary $X vs $$$X, or change the syntax anchor.";
      return cap(out.trim());
    },
  }),
  grep: tool({
    description: "Literal/regex text search. Does NOT replace ast_grep for a structural search.",
    inputSchema: z.object({ pattern: z.string(), path: z.string().default(".") }),
    execute: async ({ pattern, path: p }) => {
      const { out } = run("grep", ["-rn", "--exclude-dir=target", "--exclude-dir=.git", "-E", pattern, p]);
      return out.trim() ? cap(out.trim()) : "no matches";
    },
  }),
  glob_files: tool({
    description: "Find files by name pattern.",
    inputSchema: z.object({ pattern: z.string() }),
    execute: async ({ pattern }) => {
      const { out } = run("bash", ["-lc", `find . -path ./target -prune -o -name '${pattern}' -print | head -200`]);
      return out.trim() || "no matches";
    },
  }),
  read_file: tool({
    description: "Read a file, optionally a line range.",
    inputSchema: z.object({
      file_path: z.string(), offset: z.number().default(0), limit: z.number().default(2000),
    }),
    execute: async ({ file_path, offset, limit }) => {
      try {
        const lines = readFileSync(file_path, "utf8").split("\n");
        return cap(lines.slice(offset, offset + limit)
          .map((l, i) => `${offset + i + 1}\t${l}`).join("\n"));
      } catch (e) { return `read_file failed: ${e.message}`; }
    },
  }),
  bash: tool({
    description: "Run a shell command in the worktree.",
    inputSchema: z.object({ command: z.string(), timeout_s: z.number().default(60) }),
    execute: async ({ command, timeout_s }) => {
      const { rc, out, err } = run("bash", ["-lc", command], timeout_s * 1000);
      return cap(`exit=${rc}\n${out}${err}`);
    },
  }),
  edit_file: tool({
    description: "Replace an exact string in ONE file. For 2+ files the policy REQUIRES ast_grep.",
    inputSchema: z.object({
      file_path: z.string(), old_string: z.string(), new_string: z.string(),
    }),
    execute: async ({ file_path, old_string, new_string }) => {
      try {
        const s = readFileSync(file_path, "utf8");
        const n = s.split(old_string).length - 1;
        if (n === 0) return "old_string not found — no change made";
        if (n > 1) return `old_string appears ${n} times — not unique, no change made`;
        require_("node:fs").writeFileSync(file_path, s.replace(old_string, new_string));
        return `edited ${file_path}`;
      } catch (e) { return `edit_file failed: ${e.message}`; }
    },
  }),
  write_file: tool({
    description: "Create a NEW file.",
    inputSchema: z.object({ file_path: z.string(), content: z.string() }),
    execute: async ({ file_path, content }) => {
      try {
        require_("node:fs").writeFileSync(file_path, content);
        return `wrote ${file_path}`;
      } catch (e) { return `write_file failed: ${e.message}`; }
    },
  }),
};

const READ_ONLY_TOOLS = ["zg_query", "ast_grep", "grep", "glob_files", "read_file", "bash"];
const readOnly = /read[- ]only|do not modify|analysis only|WRITES NO CODE/i.test(TASK);
const activeAll = readOnly ? READ_ONLY_TOOLS : Object.keys(tools);

// ---- system prompt: contract FIRST, policy second (#2075) -------------------
const policy = readFileSync(POLICY, "utf8");
const contract =
  `=== YOUR TOOLS (read this before the policy) ===\n` +
  `You have EXACTLY ${activeAll.length} tools: ${activeAll.join(", ")}.\n\n` +
  `Start with zg_query, in plain English, whenever you do not already know the\n` +
  `symbol name. The index is already built for this worktree.\n\n` +
  `The policy below is written for a shell-only worker, so it spells these out as\n` +
  `COMMAND LINES. When you read those commands, they mean the tool:\n` +
  `    zg query "..."                -> zg_query\n` +
  `    ast-grep run --pattern '...'  -> ast_grep\n` +
  `    cat / sed -n '1,80p'          -> read_file\n\n` +
  `MANDATORY: before any rename, signature change, match-arm change or trait change\n` +
  `touching 2+ files, use ast_grep and log the AST-GREP-DECISION line the policy\n` +
  `requires. grep plus a per-file edit is a brief violation, not a shortcut.\n\n` +
  `IGNORE tool names in the repo CLAUDE.md and AGENTS.md — they name tools you do\n` +
  `NOT have. Their RULES still apply; only the names do not.\n`;

const system =
  `You are a full autonomous Velostream implementation worker.\n\n` +
  `MODEL:\n${MODEL}\n\nWORKTREE:\n${CWD}\n\n` +
  `You operate only inside the assigned Velostream worktree.\n\n` +
  contract +
  `\nThe following Velostream implementation policy is authoritative and mandatory:\n\n` +
  `================ VELO-IMPL POLICY ================\n${policy}\n` +
  `================ END VELO-IMPL POLICY ============\n` +
  `\n=== REMINDER ===\nThe commands the policy just showed you are registered tools here: ` +
  `zg_query, ast_grep. Use them directly.\n`;

// ---- the spike's actual subject --------------------------------------------
// Step 0 gated to discovery-only tools: bash is not merely discouraged, it is
// ABSENT from the model's tool list for that step. This is the structural
// guarantee openai-agents cannot express.
const DISCOVERY_ONLY = ["zg_query", "grep", "glob_files", "read_file"];
function prepareStep({ stepNumber }) {
  if (GATE_DISCOVERY && stepNumber === 0) {
    return { activeTools: DISCOVERY_ONLY.filter((t) => activeAll.includes(t)) };
  }
  if (!NO_FORCE && stepNumber === 0 && activeAll.includes("zg_query")) {
    return { toolChoice: { type: "tool", toolName: "zg_query" } };
  }
  return {};
}

const key = process.env.OPENROUTER_API_KEY || process.env.CODEANY_API_KEY;
if (!key) { console.error("ERROR: OPENROUTER_API_KEY not set"); process.exit(2); }
const openrouter = createOpenRouter({ apiKey: key });

emit(`[prompt 1] sdk system event=init`);
emit(`[prompt 1] start timeout_seconds=${PROMPT_TIMEOUT.toFixed(0)} backend=vercel-ai-sdk ` +
     `tools=${activeAll.length} read_only=${readOnly} ` +
     `force_first_tool=${(!NO_FORCE && !readOnly) ? "zg_query" : "none"} ` +
     `gate_discovery_step=${GATE_DISCOVERY}`);

let turns = 0, cost = 0, inTok = 0, outTok = 0, cachedTok = 0, leaked = 0;

// A leaked tool call is the model emitting its native tool-call syntax as plain
// TEXT: the parser does not recognise it, the call never runs, and the turn
// still reports success. Silent by construction, so it must be detected rather
// than hoped about. Same shapes and same two guards as the Python runner —
// fenced/inline code is stripped first (a report QUOTES the syntax, a real leak
// is bare), and each pattern needs real delimiters so prose saying "invoke"
// does not match.
const LEAK_PATTERNS = [
  ["DSML", /<[|｜]\s*DSML/],
  ["tool_call", /<\/?tool_calls?>/],
  ["function_calls", /<\/?function_calls>/],
  ["invoke", /<invoke\s+name=/],
];
function scanLeaks(text) {
  if (!text) return [];
  const scannable = String(text).replace(/```[\s\S]*?```/g, "").replace(/`[^`\n]*`/g, "");
  return LEAK_PATTERNS.filter(([, re]) => re.test(scannable)).map(([n]) => n);
}

const agent = new ToolLoopAgent({
  model: openrouter(MODEL),
  system,
  tools,
  activeTools: activeAll,
  stopWhen: stepCountIs(MAX_TURNS),
  prepareStep,
  onStepFinish(step) {
    turns += 1;
    const calls = step.toolCalls ?? [];
    if (calls.length) {
      const names = calls.map((c) => c.toolName).join(",");
      const rendered = calls
        .map((c) => `${c.toolName}(${JSON.stringify(c.input ?? {}).slice(0, 220)})`)
        .join("  ");
      emit(`[prompt 1] tool start names=${names} | ${rendered}`);
      for (const r of step.toolResults ?? []) {
        const len = typeof r.output === "string" ? r.output.length : JSON.stringify(r.output ?? "").length;
        emit(`[prompt 1] tool completed name=${r.toolName} outcome=ok result_len=${len}`);
      }
    }
    if (step.text?.length) {
      emit(`[prompt 1] sdk assistant text_len=${step.text.length}`);
      for (const kind of scanLeaks(step.text)) {
        leaked += 1;
        emit(`[prompt 1] LEAKED TOOL CALL kind=${kind} turn=${turns} — emitted as text, never executed`);
      }
    }
    const u = step.usage ?? {};
    inTok += u.inputTokens ?? 0;
    outTok += u.outputTokens ?? 0;
    cachedTok += u.cachedInputTokens ?? 0;
    const c = step.providerMetadata?.openrouter?.usage?.cost;
    if (typeof c === "number") cost += c;
    if (MAX_BUDGET !== null && cost >= MAX_BUDGET) {
      emit(`[prompt 1] budget ceiling reached cost_usd=${cost.toFixed(6)} max=${MAX_BUDGET}`);
      throw new Error("budget-ceiling");
    }
  },
});

let status = "success";
const timer = setTimeout(() => {
  emit(`[prompt 1] timeout after_seconds=${PROMPT_TIMEOUT}`);
  finish("timeout");
  process.exit(1);
}, PROMPT_TIMEOUT * 1000);

function finish(st) {
  const secs = (Date.now() - started) / 1000;
  // usage_source is 'openrouter-billed' ONLY when a real billed figure arrived.
  // Reporting an estimate under that name is how a cost table becomes fiction.
  const src = cost > 0 ? "openrouter-billed" : "unavailable";
  emit(`[prompt 1] sdk result status=${st} turns=${turns} text_len=0`);
  emit(`[prompt 1] completed in_seconds=${secs.toFixed(1)} status=${st} final_result=true`);
  emit(`TOTALS prompts=1 leaked_tool_calls=${leaked} input_tokens=${inTok} ` +
       `output_tokens=${outTok} cached_tokens=${cachedTok} cost_usd=${cost.toFixed(6)} ` +
       `usage_source=${src} read_only=${readOnly}`);
}

try {
  const res = await agent.generate({ prompt: TASK });
  if (res.text?.length) emit(`[prompt 1] sdk assistant text_len=${res.text.length}`);
} catch (e) {
  status = e.message === "budget-ceiling" ? "budget" : "error";
  emit(`[prompt 1] sdk error ${String(e.message).slice(0, 300)}`);
} finally {
  clearTimeout(timer);
  finish(status);
}
process.exit(status === "success" ? 0 : 1);
