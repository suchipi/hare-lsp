// SPDX-License-Identifier: MPL-2.0
// (c) hare-lsp authors
//
// Thin VSCode language-client wrapper around the hare-lsp binary.

import { execFile } from "node:child_process";
import { promisify } from "node:util";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  Trace,
  TransportKind,
} from "vscode-languageclient/node";

const execFileAsync = promisify(execFile);

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext): void {
  const serverPath = vscode.workspace
    .getConfiguration("hare-lsp")
    .get<string>("path") ?? "hare-lsp";
  const getTraceServer = () =>
    vscode.workspace
      .getConfiguration("hare-lsp")
      .get<string>("trace.server") ?? "off";

  // `hare.path` (the `hare` binary used by the server) is forwarded via
  // workspace/configuration; the extension itself only needs `hare-lsp.path`
  // to locate the language server binary.
  const serverOptions: ServerOptions = {
    run: {
      command: serverPath,
      transport: TransportKind.stdio,
    },
    debug: {
      command: serverPath,
      transport: TransportKind.stdio,
    },
  };

  const traceOutputChannel = vscode.window.createOutputChannel("Hare LSP");
  context.subscriptions.push(traceOutputChannel);
  traceOutputChannel.appendLine(
    `[hare-lsp] activate() — serverPath=${serverPath} traceServer=${getTraceServer()}`,
  );

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: "file", language: "hare" },
    ],
    synchronize: {
      // Forward `hare.*` setting changes to the server.
      configurationSection: "hare",
      fileEvents: vscode.workspace.createFileSystemWatcher("**/*.{ha,s}"),
    },
    initializationOptions: {
      // Some servers consult initializationOptions for one-time setup
      // alongside (or instead of) workspace/configuration. We send the
      // current `hare` settings here as a hint; the server primarily
      // uses workspace/configuration.
      hare: vscode.workspace.getConfiguration("hare"),
    },
    outputChannel: traceOutputChannel,
    traceOutputChannel,
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
