"use client";

import { ArrowRight, Smartphone } from "lucide-react";
import { CopyCommand } from "./copy-command";
import { usePlatform } from "./platform";

/** The install command and the buttons, ordered for the visitor's device. */
export function HeroActions({ command }: { command: string }) {
  const platform = usePlatform();
  const onPhone = platform === "android" || platform === "ios";

  const label =
    platform === "macos"
      ? "Install on your Mac: paste this in Terminal"
      : platform === "linux"
        ? "Install on Linux: paste this in a terminal"
        : "Install on your Mac or Linux PC: paste this in a terminal";

  const androidButton = (
    <a
      href="/download/android"
      className={
        platform === "android"
          ? "inline-flex items-center gap-2 rounded-xl bg-accent px-5 py-3 text-sm font-medium text-stone-950 transition hover:bg-accent-soft"
          : "inline-flex items-center gap-2 rounded-xl border border-line bg-surface-raised px-5 py-3 text-sm font-medium text-stone-200 transition hover:border-accent/50 hover:text-white"
      }
    >
      <Smartphone className="size-4" />
      Get the Android app
    </a>
  );

  return (
    <div className="flex flex-col gap-5">
      {platform === "android" && <div>{androidButton}</div>}
      <div className={onPhone ? "order-last" : undefined}>
        <p className="mb-2 text-sm text-stone-400">{label}</p>
        <CopyCommand command={command} />
      </div>
      <div className="flex flex-wrap items-center gap-3">
        {platform !== "android" && androidButton}
        <a
          href="#download"
          className="inline-flex items-center gap-1.5 px-2 py-3 text-sm text-stone-400 transition hover:text-white"
        >
          All downloads
          <ArrowRight className="size-4" />
        </a>
      </div>
    </div>
  );
}
