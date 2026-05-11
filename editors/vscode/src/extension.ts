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
  const config = vscode.workspace.getConfiguration("hare");
  const serverPath = vscode.workspace
    .getConfiguration("hare-lsp")
    .get<string>("path") ?? "hare-lsp";
  const traceServer = config.get<string>("trace.server") ?? "off";

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
    traceOutputChannel,
  };

  client = new LanguageClient(
    "hare-lsp",
    "Hare Language Server",
    serverOptions,
    clientOptions,
  );

  // Re-pull configuration when the user changes any `hare.*` setting.
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((event) => {
      if (event.affectsConfiguration("hare")) {
        client?.sendNotification("workspace/didChangeConfiguration", {
          settings: { hare: vscode.workspace.getConfiguration("hare") },
        });
      }
    }),
  );

  client.start();
  void client.setTrace(Trace.fromString(traceServer));

  context.subscriptions.push(
    vscode.commands.registerCommand("hare-lsp.restart", async () => {
      if (!client) return;
      await client.restart();
      void client.setTrace(Trace.fromString(traceServer));
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

  const refreshStatus = async () => {
    const harePath =
      vscode.workspace.getConfiguration("hare").get<string>("path") ?? "hare";
    const md = new vscode.MarkdownString("", true);
    md.appendMarkdown(`**Hare Language Server**\n\n`);
    md.appendMarkdown(
      `- Status: ${client?.isRunning() ? "$(check) running" : "$(error) stopped"}\n`,
    );
    md.appendMarkdown(`- Server binary: \`${serverPath}\`\n`);
    md.appendMarkdown(`- Hare binary: \`${harePath}\`\n`);
    try {
      const { stdout } = await execFileAsync(harePath, ["version"], {
        timeout: 3000,
      });
      md.appendMarkdown(`- Hare version: \`${stdout.trim()}\`\n`);
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      md.appendMarkdown(`- Hare version: _unavailable_ (${message})\n`);
    }
    statusItem.tooltip = md;
  };

  context.subscriptions.push(
    vscode.commands.registerCommand("hare-lsp.showMenu", async () => {
      const picks: Array<vscode.QuickPickItem & { command: string }> = [
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
        placeHolder: "Hare LSP",
      });
      if (choice) {
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
