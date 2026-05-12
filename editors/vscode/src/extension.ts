// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Thin VSCode language-client wrapper around the hare-lsp binary.

import { execFile, spawn } from "node:child_process";
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
      ];
      const choice = await vscode.window.showQuickPick(picks, {
        title: `Hare LSP — ${cachedVersion}`,
        placeHolder: "Hare LSP",
      });
      if (choice?.command) {
        await vscode.commands.executeCommand(choice.command);
      }
    }),
    vscode.commands.registerCommand("hare-lsp.showOutput", () => {
      traceOutputChannel.show(true);
    }),
    vscode.window.onDidChangeActiveTextEditor(() => {
      updateVisibility();
      void refreshStatus();
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
