"use client";

import { Download, Laptop, Monitor, Smartphone, Terminal } from "lucide-react";
import { useState, type ReactNode } from "react";
import { CopyCommand } from "./copy-command";
import { usePlatform, type Platform } from "./platform";

type Tab = "macos" | "linux" | "android" | "ios";

const TABS: { id: Tab; label: string; icon: ReactNode }[] = [
  { id: "macos", label: "macOS", icon: <Laptop className="size-4" /> },
  { id: "linux", label: "Linux", icon: <Monitor className="size-4" /> },
  { id: "android", label: "Android", icon: <Smartphone className="size-4" /> },
  { id: "ios", label: "iPhone", icon: <Smartphone className="size-4" /> },
];

function tabFor(platform: Platform | null): Tab {
  if (platform === "linux" || platform === "android" || platform === "ios") return platform;
  return "macos";
}

function formatSize(bytes: number | undefined): string {
  if (!bytes) return "";
  return bytes >= 1024 * 1024
    ? `${(bytes / 1024 / 1024).toFixed(1)} MB`
    : `${Math.round(bytes / 1024)} KB`;
}

function Step({ n, children }: { n: number; children: ReactNode }) {
  return (
    <li className="flex gap-4">
      <span className="flex size-7 shrink-0 items-center justify-center rounded-full border border-accent/40 bg-accent/10 text-xs font-semibold text-accent">
        {n}
      </span>
      <div className="min-w-0 flex-1 pt-0.5 text-sm leading-6 text-stone-300">{children}</div>
    </li>
  );
}

function FileLink({ href, name, size }: { href: string; name: string; size?: number }) {
  return (
    <a
      href={href}
      className="inline-flex items-center gap-2 rounded-xl bg-accent px-4 py-2.5 text-sm font-medium text-stone-950 transition hover:bg-accent-soft"
    >
      <Download className="size-4" />
      {name}
      {size ? <span className="text-stone-950/60">{formatSize(size)}</span> : null}
    </a>
  );
}

function Manual({ children }: { children: ReactNode }) {
  return (
    <details className="group mt-8 rounded-xl border border-line bg-black/20 px-4 py-3">
      <summary className="flex cursor-pointer list-none items-center gap-2 text-sm text-stone-400 transition hover:text-white">
        <Terminal className="size-4" />
        Prefer a manual download?
      </summary>
      <div className="mt-4 flex flex-col gap-3 text-sm text-stone-400">{children}</div>
    </details>
  );
}

export function DownloadTabs({
  command,
  sizes,
}: {
  command: string;
  sizes: Record<string, number>;
}) {
  const platform = usePlatform();
  const [chosen, setChosen] = useState<Tab | null>(null);
  const tab = chosen ?? tabFor(platform);

  return (
    <div className="overflow-hidden rounded-2xl border border-line bg-surface">
      <div
        role="tablist"
        aria-label="Platform"
        className="no-scrollbar flex overflow-x-auto border-b border-line"
      >
        {TABS.map((t) => (
          <button
            key={t.id}
            type="button"
            role="tab"
            aria-selected={tab === t.id}
            onClick={() => setChosen(t.id)}
            className={`flex shrink-0 items-center gap-2 border-b-2 px-5 py-4 text-sm transition ${
              tab === t.id
                ? "border-accent text-white"
                : "border-transparent text-stone-400 hover:text-stone-200"
            }`}
          >
            {t.icon}
            {t.label}
          </button>
        ))}
      </div>

      <div role="tabpanel" className="p-6 sm:p-8">
        {tab === "macos" && (
          <>
            <p className="mb-6 text-sm text-stone-400">
              macOS 13 Ventura or later · Apple silicon and Intel
            </p>
            <ol className="flex flex-col gap-5">
              <Step n={1}>
                Open <strong className="text-white">Terminal</strong> and run:
                <div className="mt-2">
                  <CopyCommand command={command} />
                </div>
              </Step>
              <Step n={2}>
                Look for the bell in the menu bar. It opens at every login.
              </Step>
              <Step n={3}>
                Click the bell, choose <strong className="text-white">Pair a Phone…</strong> and
                scan the code with the ccnotify app.
              </Step>
            </ol>
            <Manual>
              <div>
                <FileLink href="/download/macos" name="ccnotify-macos.tar.gz" size={sizes["ccnotify-macos.tar.gz"]} />
              </div>
              <p>
                The build is not notarized by Apple, so clear the quarantine flag before you run
                it:
              </p>
              <CopyCommand
                compact
                command="tar -xzf ccnotify-macos.tar.gz && xattr -dr com.apple.quarantine ccnotify ccnotify.app && ./ccnotify install"
              />
            </Manual>
          </>
        )}

        {tab === "linux" && (
          <>
            <p className="mb-6 text-sm text-stone-400">
              64-bit (x86_64) · any distribution with systemd
            </p>
            <ol className="flex flex-col gap-5">
              <Step n={1}>
                Open a terminal and run:
                <div className="mt-2">
                  <CopyCommand command={command} />
                </div>
              </Step>
              <Step n={2}>
                The bell shows in the top bar or system tray and starts at every login. On GNOME
                (other than Ubuntu), install the{" "}
                <strong className="text-white">AppIndicator and KStatusNotifierItem Support</strong>{" "}
                extension first.
              </Step>
              <Step n={3}>
                Open the bell&apos;s menu, choose{" "}
                <strong className="text-white">Pair a Phone…</strong> and scan the code with the
                ccnotify app.
              </Step>
            </ol>
            <Manual>
              <div>
                <FileLink
                  href="/download/linux"
                  name="ccnotify-linux-x86_64.tar.gz"
                  size={sizes["ccnotify-linux-x86_64.tar.gz"]}
                />
              </div>
              <CopyCommand compact command="tar -xzf ccnotify-linux-x86_64.tar.gz && ./ccnotify install" />
            </Manual>
          </>
        )}

        {tab === "android" && (
          <>
            <p className="mb-6 text-sm text-stone-400">Android 7.0 or later</p>
            <div className="mb-8">
              <FileLink
                href="/download/android"
                name="ccnotify-android.apk"
                size={sizes["ccnotify-android.apk"]}
              />
            </div>
            <ol className="flex flex-col gap-5">
              <Step n={1}>
                Open the downloaded file and allow your browser to install apps when Android asks.
              </Step>
              <Step n={2}>
                Allow notifications and <strong className="text-white">ignore battery
                optimization</strong>, or Android cuts the connection in the background.
              </Step>
              <Step n={3}>
                Tap <strong className="text-white">Pair PC</strong> and scan the code from the
                bell on your computer.
              </Step>
            </ol>
            <p className="mt-8 text-sm text-stone-500">
              Xiaomi, Samsung, Huawei and other phones stop background apps more aggressively.
              See{" "}
              <a
                href="https://dontkillmyapp.com"
                className="text-stone-300 underline decoration-stone-600 underline-offset-4 hover:text-white"
              >
                dontkillmyapp.com
              </a>{" "}
              for your model.
            </p>
          </>
        )}

        {tab === "ios" && (
          <div className="flex flex-col gap-3 py-4">
            <p className="text-base font-medium text-white">Coming soon</p>
            <p className="max-w-xl text-sm leading-6 text-stone-400">
              The iPhone app works, but it is not on the App Store yet. Until then, developers
              can build it from source with Xcode. iOS only keeps the connection while the app is
              open, or with &ldquo;Stay connected in the background&rdquo; turned on.
            </p>
          </div>
        )}
      </div>
    </div>
  );
}
