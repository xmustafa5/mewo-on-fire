"use client";

import { Check, Copy } from "lucide-react";
import { useState } from "react";

export function CopyCommand({ command, compact = false }: { command: string; compact?: boolean }) {
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(command);
      setCopied(true);
      setTimeout(() => setCopied(false), 1600);
    } catch {
      // Clipboard blocked (insecure context): the text can still be selected.
    }
  }

  return (
    <div
      className={`flex items-center gap-3 rounded-xl border border-line bg-black/50 font-mono ${
        compact ? "px-3 py-2 text-xs" : "px-4 py-3 text-sm"
      }`}
    >
      <span className="select-none text-accent" aria-hidden>
        $
      </span>
      <code className="no-scrollbar min-w-0 flex-1 overflow-x-auto whitespace-nowrap text-stone-200">
        {command}
      </code>
      <button
        type="button"
        onClick={copy}
        aria-label={copied ? "Copied" : "Copy command"}
        className="flex shrink-0 items-center gap-1.5 rounded-lg border border-line bg-surface-raised px-2.5 py-1.5 font-sans text-xs text-stone-300 transition hover:border-accent/50 hover:text-white focus-visible:outline-2 focus-visible:outline-accent"
      >
        {copied ? <Check className="size-3.5 text-emerald-400" /> : <Copy className="size-3.5" />}
        {copied ? "Copied" : "Copy"}
      </button>
    </div>
  );
}
