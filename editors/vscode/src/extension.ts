// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Thin VSCode language-client wrapper around the hare-lsp binary.

import { ChildProcess, execFile, spawn } from "node:child_process";
import { promises as fsp } from "node:fs";
import * as path from "node:path";
import { promisify } from "node:util";
import * as vscode from "vscode";
import {
  CloseAction,
  CloseHandlerResult,
  ErrorAction,
  ErrorHandler,
  ErrorHandlerResult,
  LanguageClient,
  LanguageClientOptions,
  Message,
  ServerOptions,
  Trace,
  TransportKind,
} from "vscode-languageclient/node";

const execFileAsync = promisify(execFile);

let client: LanguageClient | undefined;

type TestStatus = "passed" | "failed" | "skipped";

interface TestEntry {
  line: number;
  status: TestStatus;
}

// uri -> testName -> { line, status }. Populated as `hare test` output
// is parsed and consumed by applyDecorations() when an editor for the
// file is visible.
const testResults = new Map<string, Map<string, TestEntry>>();

interface FailureLoc {
  // URI of the file where the failing assertion lives. May differ from
  // the test source file if the test called into a helper.
  uri: string;
  line: number;
  col: number;
  message: string;
}

// Test source uri -> testName -> failure locations (usually one per
// failing test, but Hare's runner could in principle emit several).
// Indexed by *test* source so a re-run of that test can clear the
// associated underlines wherever they landed.
const testFailures = new Map<string, Map<string, FailureLoc[]>>();

let passedDecoration: vscode.TextEditorDecorationType | undefined;
let failedDecoration: vscode.TextEditorDecorationType | undefined;
let skippedDecoration: vscode.TextEditorDecorationType | undefined;
let failureDiagnostics: vscode.DiagnosticCollection | undefined;

// vscode-languageclient's default ErrorHandler shows a toast after just a
// handful of restarts and requires the user to click "Restart" to bring
// the server back. That's reasonable for a server that's expected to be
// stable; hare-lsp is young enough that crashes are mostly transient
// (parser blowing up on a half-typed file, a tool subprocess hanging,
// etc.) and a friction-free auto-restart is more useful.
//
// This handler restarts on every clean / unexpected close, up to a
// sliding-window cap. It uses linear backoff so a tight crash loop
// doesn't pin the CPU; once the cap is exceeded we surface the toast
// and stop restarting until the user explicitly restarts via the
// `hare-lsp.restart` command.
class HareLspErrorHandler implements ErrorHandler {
  // Cap consecutive restart attempts in any one window. A real crash
  // loop will hit this fast; a server that crashes once and stays up
  // after a restart will let `recent` decay.
  private static readonly MAX_RESTARTS_IN_WINDOW = 10;
  // Window over which restarts are counted, in ms. Tight crash loops
  // tend to be sub-second; this generous window also catches "stable
  // for a minute, then crashes again" patterns.
  private static readonly WINDOW_MS = 3 * 60_000;
  // Linear backoff floor between restart attempts. Keeps the CPU
  // calm if the server is failing to even start.
  private static readonly MIN_RESTART_DELAY_MS = 500;
  // Cap the per-restart delay so the user doesn't sit through minutes
  // of waiting after a few flaps.
  private static readonly MAX_RESTART_DELAY_MS = 10_000;

  private recent: number[] = [];
  private errorCount = 0;

  constructor(private readonly channel: vscode.OutputChannel) {}

  error(
    error: Error,
    _message: Message | undefined,
    count: number | undefined,
  ): ErrorHandlerResult {
    this.errorCount = count ?? this.errorCount + 1;
    this.channel.appendLine(
      `[hare-lsp] transport error (count=${this.errorCount}): ${error.message}`,
    );
    // Continue for a few errors; ask the client to shut down only if the
    // transport is clearly hosed (matches the default's threshold).
    if (this.errorCount <= 3) {
      return { action: ErrorAction.Continue };
    }
    return { action: ErrorAction.Shutdown };
  }

  async closed(): Promise<CloseHandlerResult> {
    const now = Date.now();
    this.recent = this.recent.filter(
      (t) => now - t < HareLspErrorHandler.WINDOW_MS,
    );
    this.recent.push(now);

    if (this.recent.length > HareLspErrorHandler.MAX_RESTARTS_IN_WINDOW) {
      this.channel.appendLine(
        `[hare-lsp] server exited ${this.recent.length} times in the last ` +
          `${HareLspErrorHandler.WINDOW_MS / 1000}s; giving up. ` +
          `Run "Restart Hare LSP" to try again.`,
      );
      return {
        action: CloseAction.DoNotRestart,
        message: `hare-lsp crashed repeatedly. Check the Hare LSP output channel for details, ` +
          `then run "Restart Hare LSP" from the command palette.`,
      };
    }

    // Linear backoff: 0.5s, 1s, 1.5s, ... up to 10s.
    const delay = Math.min(
      HareLspErrorHandler.MIN_RESTART_DELAY_MS * this.recent.length,
      HareLspErrorHandler.MAX_RESTART_DELAY_MS,
    );
    this.channel.appendLine(
      `[hare-lsp] server exited; auto-restart #${this.recent.length} in ${delay}ms`,
    );
    if (delay > 0) {
      await new Promise((resolve) => setTimeout(resolve, delay));
    }
    return { action: CloseAction.Restart };
  }
}

export function activate(context: vscode.ExtensionContext): void {
  const mkDecoration = (name: TestStatus, ruler: string) =>
    vscode.window.createTextEditorDecorationType({
      gutterIconPath: vscode.Uri.file(
        context.asAbsolutePath(`media/test-${name}.svg`),
      ),
      gutterIconSize: "contain",
      overviewRulerColor: ruler,
      overviewRulerLane: vscode.OverviewRulerLane.Left,
    });
  passedDecoration = mkDecoration("passed", "#3fb950");
  failedDecoration = mkDecoration("failed", "#f85149");
  skippedDecoration = mkDecoration("skipped", "#d4a72c");
  failureDiagnostics = vscode.languages.createDiagnosticCollection("hare-test");
  context.subscriptions.push(
    passedDecoration,
    failedDecoration,
    skippedDecoration,
    failureDiagnostics,
  );

  const serverPath = vscode.workspace
    .getConfiguration("hare-lsp")
    .get<string>("path") ?? "hare-lsp";
  const getTraceServer = () =>
    vscode.workspace
      .getConfiguration("hare-lsp")
      .get<string>("trace.server") ?? "off";

  const traceOutputChannel = vscode.window.createOutputChannel("Hare LSP");
  context.subscriptions.push(traceOutputChannel);
  traceOutputChannel.appendLine(
    `[hare-lsp] activate() — serverPath=${serverPath} traceServer=${getTraceServer()}`,
  );

  // Spawn the server ourselves rather than letting vscode-languageclient do
  // it via the `Executable` shape. That lets us attach explicit listeners on
  // stderr and the exit event so any crash, abort message, or runtime error
  // shows up in the Hare LSP output channel instead of being lost to the
  // ether — vscode's "server crashed N times" message is otherwise useless
  // for diagnosis.
  // `hare.path` (the `hare` binary used internally by the server) is
  // forwarded via workspace/configuration; the extension only needs
  // `hare-lsp.path` to locate the server binary itself.
  const serverOptions: ServerOptions = () =>
    new Promise((resolve, reject) => {
      const child = spawn(serverPath, [], {
        stdio: ["pipe", "pipe", "pipe"],
      });
      child.on("error", (err) => {
        traceOutputChannel.appendLine(
          `[hare-lsp] spawn error: ${err.message}`,
        );
        reject(err);
      });
      child.stderr?.on("data", (chunk: Buffer | string) => {
        const text = typeof chunk === "string"
          ? chunk
          : chunk.toString("utf8");
        // Server stderr lines come without our [hare-lsp] prefix; tag
        // them so they're distinguishable from extension-side logs and
        // from vscode-languageclient's [Trace - ...] entries.
        for (const line of text.split(/\r?\n/)) {
          if (line.length === 0) continue;
          traceOutputChannel.appendLine(`[server-stderr] ${line}`);
        }
      });
      child.on("exit", (code, signal) => {
        traceOutputChannel.appendLine(
          `[hare-lsp] server process exited code=${code} signal=${signal}`,
        );
      });
      resolve(child);
    });

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: "file", language: "hare" },
    ],
    synchronize: {
      // Forward `hare.*` setting changes to the server.
      configurationSection: "hare",
      // Only watch Hare source. Assembly (`*.s`) is part of a module's
      // source set per Hare's rules but the LSP doesn't parse it; the
      // qbe-output `.cache/*.o.tmp.s` artifacts also matched
      // `**/*.{ha,s}` and crashed the server when fed to the parser.
      fileEvents: vscode.workspace.createFileSystemWatcher("**/*.ha"),
    },
    initializationOptions: {
      // Some servers consult initializationOptions for one-time setup
      // alongside (or instead of) workspace/configuration. We send the
      // current `hare` settings here as a hint; the server primarily
      // uses workspace/configuration.
      hare: vscode.workspace.getConfiguration("hare"),
    },
    middleware: {
      // The server emits `[[name]]` doc-comment refs as markdown links
      // whose href is a `command:hare-lsp.openLocation?...` URI. VSCode
      // refuses to invoke `command:` URIs from hover content unless the
      // MarkdownString is marked trusted, so re-wrap the contents here.
      provideHover: async (document, position, token, next) => {
        const hover = await next(document, position, token);
        if (!hover) return hover;
        const trust = (
          c: vscode.MarkdownString | vscode.MarkedString,
        ): vscode.MarkdownString | vscode.MarkedString => {
          if (c instanceof vscode.MarkdownString) {
            const md = new vscode.MarkdownString(c.value, c.supportThemeIcons);
            md.isTrusted = { enabledCommands: ["hare-lsp.openLocation"] };
            md.supportHtml = c.supportHtml;
            return md;
          }
          return c;
        };
        return new vscode.Hover(hover.contents.map(trust), hover.range);
      },
      // Intercept the two CodeLens-invoked commands and run them in a
      // dedicated terminal client-side. vscode-languageclient's
      // ExecuteCommandFeature auto-registers a VSCode command for every
      // entry in the server's executeCommandProvider.commands list and
      // wires it to workspace/executeCommand; registering them manually
      // collides with that auto-registration and crashes initialize. The
      // middleware path runs for both the auto-registered command (the
      // lens click) and any other code that calls
      // `client.sendRequest("workspace/executeCommand", ...)`, so we get
      // a single interception point. Other commands fall through to the
      // server's executeCommand handler.
      executeCommand: async (command, args, next) => {
        if (command === "hare-lsp.runTest") {
          const uri = typeof args[0] === "string" ? args[0] : undefined;
          if (!uri) return null;
          const testName = typeof args[1] === "string" ? args[1] : undefined;
          const modulePath = resolveModulePath(uri);
          const hareArgs = ["test", modulePath.relative];
          if (testName && testName.length > 0) hareArgs.push(testName);
          const label = testName && testName.length > 0
            ? `hare test: ${testName}`
            : `hare test: ${modulePath.relative}`;
          await saveIfDirty(uri);
          // Look up which lines the tests live on so output parsing can
          // attach gutter status to the right ranges.
          const lenses = await fetchTestLenses(uri);
          const lineOf = new Map<string, number>();
          for (const l of lenses) lineOf.set(l.name, l.line);
          // Clear previously recorded results for the tests we're about
          // to re-run so stale gutter icons and underlines disappear
          // immediately.
          const perFile = testResults.get(uri);
          if (perFile) {
            if (testName && testName.length > 0) {
              perFile.delete(testName);
            } else {
              perFile.clear();
            }
            refreshDecorationsForUri(uri);
          }
          clearFailuresFor(uri, testName && testName.length > 0 ? testName : undefined);
          const parser = createTestOutputParser({
            cwd: modulePath.cwd,
            onResult: (name, status) => {
              const line = lineOf.get(name);
              if (line === undefined) return;
              recordTestResult(uri, name, line, status);
            },
            onFailure: (name, failUri, fline, fcol, message) => {
              recordTestFailure(uri, name, {
                uri: failUri,
                line: fline,
                col: fcol,
                message,
              });
            },
          });
          runHareInTerminal(hareArgs, modulePath.cwd, label, traceOutputChannel, parser);
          return null;
        }
        if (command === "hare-lsp.runModule") {
          const uri = typeof args[0] === "string" ? args[0] : undefined;
          if (!uri) return null;
          const modulePath = resolveModulePath(uri);
          runHareInTerminal(
            ["run", modulePath.relative],
            modulePath.cwd,
            `hare run: ${modulePath.relative}`,
            traceOutputChannel,
          );
          return null;
        }
        return next(command, args);
      },
    },
    outputChannel: traceOutputChannel,
    traceOutputChannel,
    // Auto-restart on crash with linear backoff. The default handler
    // surfaces a prompt after a handful of crashes; we instead try
    // harder before bothering the user, since most early-stage hare-lsp
    // crashes recover after a clean spawn.
    errorHandler: new HareLspErrorHandler(traceOutputChannel),
  };

  client = new LanguageClient(
    "hare-lsp",
    "Hare Language Server",
    serverOptions,
    clientOptions,
  );

  // Re-pull configuration when the user changes any `hare.*` setting.
  // `hare-lsp.trace.server` is auto-watched by vscode-languageclient since
  // it matches the client id, so we don't need to handle it here.
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("hare")) {
        client?.sendNotification("workspace/didChangeConfiguration", {
          settings: { hare: vscode.workspace.getConfiguration("hare") },
        });
      }
    }),
  );

  traceOutputChannel.appendLine(`[hare-lsp] calling client.start()`);
  client.start().then(
    () => {
      traceOutputChannel.appendLine(
        `[hare-lsp] client.start() resolved (running=${client?.isRunning() ?? false})`,
      );
    },
    (err) => {
      const message = err instanceof Error ? err.message : String(err);
      const stack = err instanceof Error ? err.stack ?? "" : "";
      traceOutputChannel.appendLine(
        `[hare-lsp] client.start() failed: ${message}\n${stack}`,
      );
      void vscode.window.showErrorMessage(
        `Hare LSP failed to start: ${message}`,
      );
    },
  );
  void client.setTrace(Trace.fromString(getTraceServer()));

  context.subscriptions.push(
    vscode.commands.registerCommand("hare-lsp.restart", async () => {
      if (!client) return;
      await client.restart();
      void client.setTrace(Trace.fromString(getTraceServer()));
      void refreshStatus();
    }),
    // Invoked by the "N references" CodeLens emitted by codelens.ha. The
    // server passes (uri, position) as arguments; we fetch references
    // via the LSP and hand them to VSCode's built-in references peek.
    vscode.commands.registerCommand(
      "hare-lsp.showReferences",
      async (uri: string, position: { line: number; character: number }) => {
        if (!client) return;
        const locations = (await client.sendRequest(
          "textDocument/references",
          {
            textDocument: { uri },
            position,
            context: { includeDeclaration: false },
          },
        )) as Array<{
          uri: string;
          range: {
            start: { line: number; character: number };
            end: { line: number; character: number };
          };
        }> | null;
        const vsLocations = (locations ?? []).map(
          (loc) =>
            new vscode.Location(
              vscode.Uri.parse(loc.uri),
              new vscode.Range(
                new vscode.Position(loc.range.start.line, loc.range.start.character),
                new vscode.Position(loc.range.end.line, loc.range.end.character),
              ),
            ),
        );
        await vscode.commands.executeCommand(
          "editor.action.showReferences",
          vscode.Uri.parse(uri),
          new vscode.Position(position.line, position.character),
          vsLocations,
        );
      },
    ),
    // Invoked from `[[name]]` markdown links in hover content. The server
    // resolved the ref to a (uri, position) and encoded that as JSON in
    // the command's query string; we open the file and reveal the range.
    vscode.commands.registerCommand(
      "hare-lsp.openLocation",
      async (uri: string, position: { line: number; character: number }) => {
        const target = vscode.Uri.parse(uri);
        const pos = new vscode.Position(position.line, position.character);
        const editor = await vscode.window.showTextDocument(target, {
          selection: new vscode.Range(pos, pos),
        });
        editor.revealRange(
          new vscode.Range(pos, pos),
          vscode.TextEditorRevealType.InCenterIfOutsideViewport,
        );
      },
    ),
  );

  const statusItem = vscode.window.createStatusBarItem(
    "hare-lsp.status",
    vscode.StatusBarAlignment.Right,
    100,
  );
  statusItem.name = "Hare LSP";
  statusItem.text = "$(symbol-namespace) Hare";
  statusItem.command = "hare-lsp.showMenu";
  context.subscriptions.push(statusItem);

  const updateVisibility = () => {
    const editor = vscode.window.activeTextEditor;
    if (editor && editor.document.languageId === "hare") {
      statusItem.show();
    } else {
      statusItem.hide();
    }
  };

  const buildTooltip = (versionLine: string): vscode.MarkdownString => {
    const harePath =
      vscode.workspace.getConfiguration("hare").get<string>("path") ?? "hare";
    let running = false;
    try {
      running = client?.isRunning() ?? false;
    } catch {
      // isRunning() can throw if called before the client is fully initialized.
    }
    const md = new vscode.MarkdownString("", true);
    md.isTrusted = true;
    md.appendMarkdown(`**Hare Language Server**\n\n`);
    md.appendMarkdown(
      `- Status: ${running ? "$(check) running" : "$(error) stopped"}\n`,
    );
    md.appendMarkdown(`- Server binary: \`${serverPath}\`\n`);
    md.appendMarkdown(`- Hare binary: \`${harePath}\`\n`);
    md.appendMarkdown(`- Hare version: ${versionLine}\n\n`);
    md.appendMarkdown(`_Click for actions_`);
    return md;
  };

  statusItem.tooltip = buildTooltip("_loading…_");

  let cachedVersion = "loading…";

  const refreshStatus = async () => {
    const harePath =
      vscode.workspace.getConfiguration("hare").get<string>("path") ?? "hare";
    statusItem.tooltip = buildTooltip(`_${cachedVersion}_`);
    try {
      const { stdout } = await execFileAsync(harePath, ["version"], {
        timeout: 3000,
      });
      cachedVersion = stdout.trim();
      statusItem.tooltip = buildTooltip(`\`${cachedVersion}\``);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      traceOutputChannel.appendLine(`[hare-lsp] hare version failed: ${message}`);
      cachedVersion = `unavailable (${message})`;
      statusItem.tooltip = buildTooltip(`_${cachedVersion}_`);
    }
  };

  const openExternal = (url: string) =>
    vscode.env.openExternal(vscode.Uri.parse(url));

  const findHareStdlibPath = async (): Promise<string | undefined> => {
    const candidates: string[] = [];
    const collect = (raw: string | undefined | null) => {
      if (!raw) return;
      for (const entry of raw.split(":")) {
        if (!entry) continue;
        if (path.basename(entry) === "stdlib") candidates.push(entry);
      }
    };
    collect(
      vscode.workspace.getConfiguration("hare").get<string>("harepath"),
    );
    collect(process.env.HAREPATH);
    candidates.push("/usr/src/hare/stdlib", "/usr/local/src/hare/stdlib");
    for (const c of candidates) {
      try {
        const stat = await fsp.stat(c);
        if (stat.isDirectory()) return c;
      } catch {
        // ignore missing / unreadable candidates
      }
    }
    return undefined;
  };

  context.subscriptions.push(
    vscode.commands.registerCommand("hare-lsp.showMenu", async () => {
      const harePath =
        vscode.workspace.getConfiguration("hare").get<string>("path") ?? "hare";
      const picks: Array<vscode.QuickPickItem & { command?: string }> = [
        {
          label: `Hare binary: ${harePath}`,
          description: cachedVersion,
          kind: vscode.QuickPickItemKind.Separator,
        },
        {
          label: `Server binary: ${serverPath}`,
          kind: vscode.QuickPickItemKind.Separator,
        },
        {
          label: "$(refresh) Restart Hare LSP",
          command: "hare-lsp.restart",
        },
        {
          label: "$(output) Show Hare LSP Output",
          command: "hare-lsp.showOutput",
        },
        {
          label: "Resources",
          kind: vscode.QuickPickItemKind.Separator,
        },
        {
          label: "$(globe) Open Hare Website",
          command: "hare-lsp.openWebsite",
        },
        {
          label: "$(book) Open Hare Documentation",
          command: "hare-lsp.openDocs",
        },
        {
          label: "$(mortar-board) Open Hare Tutorial",
          command: "hare-lsp.openTutorial",
        },
        {
          label: "$(law) Open Hare Specification",
          command: "hare-lsp.openSpecification",
        },
        {
          label: "$(library) Open Standard Library Docs",
          command: "hare-lsp.openStdlibDocs",
        },
        {
          label: "$(cloud-download) Open Hare Installation Guide",
          command: "hare-lsp.openInstallGuide",
        },
        {
          label: "$(folder-opened) Open Hare stdlib in New Window",
          command: "hare-lsp.openStdlibFolder",
        },
      ];
      const choice = await vscode.window.showQuickPick(picks, {
        title: `Hare LSP - ${cachedVersion}`,
        placeHolder: "Hare LSP",
      });
      if (choice?.command) {
        await vscode.commands.executeCommand(choice.command);
      }
    }),
    vscode.commands.registerCommand("hare-lsp.showOutput", () => {
      traceOutputChannel.show(true);
    }),
    vscode.commands.registerCommand("hare-lsp.openWebsite", () =>
      openExternal("https://harelang.org/"),
    ),
    vscode.commands.registerCommand("hare-lsp.openDocs", () =>
      openExternal("https://harelang.org/documentation/"),
    ),
    vscode.commands.registerCommand("hare-lsp.openTutorial", () =>
      openExternal("https://harelang.org/tutorials/"),
    ),
    vscode.commands.registerCommand("hare-lsp.openSpecification", () =>
      openExternal("https://harelang.org/specification/"),
    ),
    vscode.commands.registerCommand("hare-lsp.openStdlibDocs", () =>
      openExternal("https://docs.harelang.org"),
    ),
    vscode.commands.registerCommand("hare-lsp.openInstallGuide", () =>
      openExternal("https://harelang.org/documentation/install/"),
    ),
    vscode.commands.registerCommand("hare-lsp.openStdlibFolder", async () => {
      const resolved = await findHareStdlibPath();
      if (!resolved) {
        void vscode.window.showErrorMessage(
          "Could not find a Hare stdlib directory. Set `hare.harepath` to point at it.",
        );
        return;
      }
      await vscode.commands.executeCommand(
        "vscode.openFolder",
        vscode.Uri.file(resolved),
        { forceNewWindow: true },
      );
    }),
    vscode.window.onDidChangeActiveTextEditor((editor) => {
      updateVisibility();
      void refreshStatus();
      if (editor) applyDecorations(editor);
    }),
    vscode.window.onDidChangeVisibleTextEditors((editors) => {
      for (const editor of editors) applyDecorations(editor);
    }),
    vscode.commands.registerCommand("hare-lsp.runTestsInFile", async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor || editor.document.languageId !== "hare") {
        void vscode.window.showWarningMessage(
          "Open a Hare file to run its tests.",
        );
        return;
      }
      if (editor.document.isDirty) await editor.document.save();
      const uri = editor.document.uri.toString();
      const lenses = await fetchTestLenses(uri);
      if (lenses.length === 0) {
        void vscode.window.showInformationMessage(
          "No @test functions found in this file.",
        );
        return;
      }
      const modulePath = resolveModulePath(uri);
      const lineOf = new Map<string, number>();
      const names: string[] = [];
      for (const l of lenses) {
        lineOf.set(l.name, l.line);
        names.push(l.name);
      }
      const perFile = testResults.get(uri);
      if (perFile) {
        perFile.clear();
        refreshDecorationsForUri(uri);
      }
      clearFailuresFor(uri);
      const parser = createTestOutputParser({
        cwd: modulePath.cwd,
        onResult: (name, status) => {
          const line = lineOf.get(name);
          if (line === undefined) return;
          recordTestResult(uri, name, line, status);
        },
        onFailure: (name, failUri, fline, fcol, message) => {
          recordTestFailure(uri, name, {
            uri: failUri,
            line: fline,
            col: fcol,
            message,
          });
        },
      });
      runHareInTerminal(
        ["test", modulePath.relative, ...names],
        modulePath.cwd,
        `hare test: ${path.basename(editor.document.uri.fsPath)} (${names.length} tests)`,
        traceOutputChannel,
        parser,
      );
    }),
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("hare.path")) {
        void refreshStatus();
      }
    }),
  );

  context.subscriptions.push(
    client.onDidChangeState((e) => {
      traceOutputChannel.appendLine(
        `[hare-lsp] state change: ${e.oldState} -> ${e.newState}`,
      );
      void refreshStatus();
    }),
  );

  updateVisibility();
  void refreshStatus();

  context.subscriptions.push({
    dispose: () => {
      void client?.stop();
    },
  });
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}

// Resolves a file URI (from a CodeLens command argument) to a working
// directory and module path suitable for `hare test` / `hare run`. The
// CWD is the enclosing workspace folder when one is known so that
// `hare`'s build cache lands at the workspace root rather than next to
// the file being tested; the module path is the file's directory
// expressed relative to that CWD.
function resolveModulePath(uri: string): { cwd: string; relative: string } {
  const fileUri = vscode.Uri.parse(uri);
  const fileDir = path.dirname(fileUri.fsPath);
  const folder = vscode.workspace.getWorkspaceFolder(fileUri);
  const cwd = folder?.uri.fsPath ?? fileDir;
  const rel = path.relative(cwd, fileDir);
  return { cwd, relative: rel.length > 0 ? rel : "." };
}

// Queries the server for code lenses on `uri`, then filters to the
// `▶ Run test: <name>` lenses and extracts (name, line) for each. The
// server emits these eagerly (no codeLens/resolve needed), so the
// command + arguments are always populated.
async function fetchTestLenses(
  uri: string,
): Promise<Array<{ name: string; line: number }>> {
  if (!client) return [];
  type LspCodeLens = {
    range: { start: { line: number; character: number } };
    command?: { command: string; arguments?: unknown[] };
  };
  let lenses: LspCodeLens[] | null = null;
  try {
    lenses = await client.sendRequest<LspCodeLens[] | null>(
      "textDocument/codeLens",
      { textDocument: { uri } },
    );
  } catch {
    return [];
  }
  if (!lenses) return [];
  const out: Array<{ name: string; line: number }> = [];
  for (const lens of lenses) {
    const cmd = lens.command;
    if (!cmd || cmd.command !== "hare-lsp.runTest") continue;
    const args = cmd.arguments ?? [];
    if (args.length < 2) continue;
    const name = typeof args[1] === "string" ? args[1] : "";
    if (name.length === 0) continue;
    out.push({ name, line: lens.range.start.line });
  }
  return out;
}

// Hare's test runner prints one line per test in the form
// `<name>.....PASS in 0.000006000s` (FAIL / SKIP variants share the
// shape). ANSI color codes only fire when stdout is a tty, and we spawn
// over a pipe, so no escape stripping is needed.
const TEST_RESULT_RE =
  /^([A-Za-z_][A-Za-z0-9_]*)\.{2,}(PASS|FAIL|SKIP) in \d+\.\d+s\s*$/;

// In the post-run `Failures:` section, each failure with a known
// location prints as `<testname>: <path>:<line>:<col>: <message>`.
// Backtrace lines (when present) start with hex addresses and don't
// match this shape.
const TEST_FAILURE_RE =
  /^([A-Za-z_][A-Za-z0-9_]*): ([^:]+):(\d+):(\d+): (.+)$/;

function parseTestStatus(status: string): TestStatus | undefined {
  if (status === "PASS") return "passed";
  if (status === "FAIL") return "failed";
  if (status === "SKIP") return "skipped";
  return undefined;
}

interface ParserCallbacks {
  cwd: string;
  onResult: (name: string, status: TestStatus) => void;
  onFailure: (
    testName: string,
    uri: string,
    line: number,
    col: number,
    message: string,
  ) => void;
}

// Stateful line-buffered parser. Returns a function that should be
// called with each chunk of child stdout/stderr; it invokes `onResult`
// for each per-test status line and `onFailure` for each failure entry
// in the trailing `Failures:` section.
function createTestOutputParser(
  cb: ParserCallbacks,
): (chunk: string) => void {
  let buf = "";
  return (chunk: string): void => {
    buf += chunk;
    for (;;) {
      const idx = buf.indexOf("\n");
      if (idx < 0) break;
      const line = buf.slice(0, idx).replace(/\r$/, "");
      buf = buf.slice(idx + 1);
      const r = TEST_RESULT_RE.exec(line);
      if (r) {
        const status = parseTestStatus(r[2]);
        if (status) cb.onResult(r[1], status);
        continue;
      }
      const f = TEST_FAILURE_RE.exec(line);
      if (f) {
        const rawPath = f[2];
        const absPath = path.isAbsolute(rawPath)
          ? rawPath
          : path.resolve(cb.cwd, rawPath);
        const uri = vscode.Uri.file(absPath).toString();
        cb.onFailure(f[1], uri, Number(f[3]), Number(f[4]), f[5]);
      }
    }
  };
}

function applyDecorations(editor: vscode.TextEditor): void {
  if (editor.document.languageId !== "hare") return;
  if (!passedDecoration || !failedDecoration || !skippedDecoration) return;
  const uri = editor.document.uri.toString();
  const entries = testResults.get(uri);
  const passed: vscode.DecorationOptions[] = [];
  const failed: vscode.DecorationOptions[] = [];
  const skipped: vscode.DecorationOptions[] = [];
  if (entries) {
    for (const [name, entry] of entries) {
      const range = new vscode.Range(entry.line, 0, entry.line, 0);
      const hover = new vscode.MarkdownString(
        `Hare test \`${name}\`: **${entry.status}**`,
      );
      const opts: vscode.DecorationOptions = { range, hoverMessage: hover };
      if (entry.status === "passed") passed.push(opts);
      else if (entry.status === "failed") failed.push(opts);
      else skipped.push(opts);
    }
  }
  editor.setDecorations(passedDecoration, passed);
  editor.setDecorations(failedDecoration, failed);
  editor.setDecorations(skippedDecoration, skipped);
}

function refreshDecorationsForUri(uri: string): void {
  for (const editor of vscode.window.visibleTextEditors) {
    if (editor.document.uri.toString() === uri) applyDecorations(editor);
  }
}

// `hare test` reads from disk, so an unsaved buffer would be tested
// against its on-disk contents. Save the matching document first so
// the user is running what they see.
async function saveIfDirty(uri: string): Promise<void> {
  for (const doc of vscode.workspace.textDocuments) {
    if (doc.uri.toString() !== uri) continue;
    if (doc.isDirty) await doc.save();
    return;
  }
}

function recordTestResult(uri: string, name: string, line: number, status: TestStatus): void {
  let perFile = testResults.get(uri);
  if (!perFile) {
    perFile = new Map();
    testResults.set(uri, perFile);
  }
  perFile.set(name, { line, status });
  refreshDecorationsForUri(uri);
}

// Walks `testFailures`, groups failure locations by target uri, and
// republishes the diagnostic collection. Cheap enough for the volume
// of failures a single `hare test` run produces.
function rebuildFailureDiagnostics(): void {
  if (!failureDiagnostics) return;
  const byTarget = new Map<string, vscode.Diagnostic[]>();
  for (const perFile of testFailures.values()) {
    for (const [testName, locs] of perFile) {
      for (const loc of locs) {
        const start = new vscode.Position(
          Math.max(0, loc.line - 1),
          Math.max(0, loc.col - 1),
        );
        // Try to extend to the end of the line so the wavy underline
        // is visible even when no doc is open we fall back to a
        // zero-width range, which VSCode still renders as a 1-char
        // wavy underline.
        let end = start;
        for (const doc of vscode.workspace.textDocuments) {
          if (doc.uri.toString() === loc.uri) {
            const lineLen = doc.lineAt(start.line).range.end.character;
            end = new vscode.Position(start.line, lineLen);
            break;
          }
        }
        const diag = new vscode.Diagnostic(
          new vscode.Range(start, end),
          `${loc.message}\nFailing test: ${testName}`,
          vscode.DiagnosticSeverity.Error,
        );
        diag.source = "hare test";
        let bucket = byTarget.get(loc.uri);
        if (!bucket) {
          bucket = [];
          byTarget.set(loc.uri, bucket);
        }
        bucket.push(diag);
      }
    }
  }
  failureDiagnostics.clear();
  for (const [uri, diags] of byTarget) {
    failureDiagnostics.set(vscode.Uri.parse(uri), diags);
  }
}

function recordTestFailure(
  sourceUri: string,
  testName: string,
  loc: FailureLoc,
): void {
  let perFile = testFailures.get(sourceUri);
  if (!perFile) {
    perFile = new Map();
    testFailures.set(sourceUri, perFile);
  }
  let arr = perFile.get(testName);
  if (!arr) {
    arr = [];
    perFile.set(testName, arr);
  }
  arr.push(loc);
  rebuildFailureDiagnostics();
}

// Clears failure entries for one test (when re-running just that test)
// or for every test in `sourceUri` (when running all tests in a file).
function clearFailuresFor(sourceUri: string, testName?: string): void {
  const perFile = testFailures.get(sourceUri);
  if (!perFile) return;
  if (testName === undefined) perFile.clear();
  else perFile.delete(testName);
  rebuildFailureDiagnostics();
}

// Backing session for the singleton "Hare" terminal. Created lazily on
// the first run; replaced when the user closes the terminal. Subsequent
// runs reuse the same session so output accumulates in one place rather
// than spawning a fresh terminal per click.
class HareTerminalSession {
  private writeEmitter = new vscode.EventEmitter<string>();
  private closeEmitter = new vscode.EventEmitter<number | void>();
  private terminal: vscode.Terminal;
  private currentChild: ChildProcess | undefined;
  private opened = false;
  // Run requests that arrive before `open` fires (e.g. the very first
  // click) are buffered and replayed once the pty is ready.
  private pending: Array<() => void> = [];
  private closed = false;

  constructor() {
    const pty: vscode.Pseudoterminal = {
      onDidWrite: this.writeEmitter.event,
      onDidClose: this.closeEmitter.event,
      open: () => {
        this.opened = true;
        const queued = this.pending;
        this.pending = [];
        for (const fn of queued) fn();
      },
      close: () => {
        this.closed = true;
        this.currentChild?.kill("SIGTERM");
        if (activeHareSession === this) activeHareSession = undefined;
        this.closeEmitter.fire(0);
      },
    };
    this.terminal = vscode.window.createTerminal({ name: "Hare", pty });
  }

  get isClosed(): boolean {
    return this.closed;
  }

  run(
    harePath: string,
    argv: string[],
    cwd: string,
    env: Record<string, string>,
    onChunk?: (text: string) => void,
  ): void {
    this.terminal.show(true);
    const start = () => this.spawnChild(harePath, argv, cwd, env, onChunk);
    if (this.opened) start();
    else this.pending.push(start);
  }

  private spawnChild(
    harePath: string,
    argv: string[],
    cwd: string,
    env: Record<string, string>,
    onChunk: ((text: string) => void) | undefined,
  ): void {
    // If a previous run is still in flight, kill it before starting a
    // new one. Its exit handler will still fire later; the guard in the
    // handler keeps it from clobbering `currentChild`.
    if (
      this.currentChild
      && this.currentChild.exitCode === null
      && this.currentChild.signalCode === null
    ) {
      this.writeEmitter.fire(`\r\n[interrupting previous run]\r\n`);
      this.currentChild.kill("SIGTERM");
    }
    this.writeEmitter.fire(`\r\n$ ${harePath} ${argv.join(" ")}\r\n`);
    this.writeEmitter.fire(`  (cwd: ${cwd})\r\n\r\n`);

    let child: ChildProcess;
    try {
      child = spawn(harePath, argv, {
        cwd,
        env,
        stdio: ["ignore", "pipe", "pipe"],
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      this.writeEmitter.fire(`[spawn error: ${message}]\r\n`);
      return;
    }
    this.currentChild = child;
    const onData = (chunk: Buffer | string) => {
      const text = typeof chunk === "string" ? chunk : chunk.toString("utf8");
      // Terminals require CRLF; the child emits bare LF.
      this.writeEmitter.fire(text.replace(/\r?\n/g, "\r\n"));
      if (onChunk) onChunk(text);
    };
    child.stdout?.on("data", onData);
    child.stderr?.on("data", onData);
    child.on("error", (err) => {
      this.writeEmitter.fire(`\r\n[spawn error: ${err.message}]\r\n`);
    });
    child.on("exit", (code, signal) => {
      if (this.currentChild === child) this.currentChild = undefined;
      const tail = signal
        ? `\r\n[exited via signal ${signal}]\r\n`
        : `\r\n[exited with code ${code ?? 0}]\r\n`;
      this.writeEmitter.fire(tail);
    });
  }
}

let activeHareSession: HareTerminalSession | undefined;

// Spawns `hare <args>` in the shared "Hare" terminal so the user sees
// live output (the server-side handler used `window/logMessage`, which
// is invisible unless the Hare LSP output channel is focused). Build
// tags configured via `hare.tags` are forwarded as `-T <tag>` pairs to
// match the server's `hare build` invocation. Subsequent calls reuse
// the same terminal until the user dismisses it.
function runHareInTerminal(
  args: string[],
  cwd: string,
  label: string,
  channel: vscode.OutputChannel,
  onChunk?: (text: string) => void,
): void {
  const config = vscode.workspace.getConfiguration("hare");
  const harePath = config.get<string>("path") ?? "hare";
  const tags = config.get<string[]>("tags") ?? [];
  const harepath = config.get<string>("harepath") ?? "";

  const argv = [args[0]];
  for (const tag of tags) {
    argv.push("-T", tag);
  }
  for (let i = 1; i < args.length; i += 1) argv.push(args[i]);

  const env: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) {
    if (typeof v === "string") env[k] = v;
  }
  if (harepath.length > 0) env.HAREPATH = harepath;

  channel.appendLine(`[hare-lsp] ${label} - ${harePath} ${argv.join(" ")} (cwd=${cwd})`);
  if (!activeHareSession || activeHareSession.isClosed) {
    activeHareSession = new HareTerminalSession();
  }
  activeHareSession.run(harePath, argv, cwd, env, onChunk);
}
