import {
  Bell,
  BellRing,
  ListChecks,
  Lock,
  MessagesSquare,
  PanelTop,
  QrCode,
  Reply,
  ShieldCheck,
  Wifi,
} from "lucide-react";
import type { ReactNode } from "react";
import { DownloadTabs } from "@/components/download-tabs";
import { HeroActions } from "@/components/hero-actions";
import { HeroVisual } from "@/components/hero-visual";
import { getLatestRelease } from "@/lib/release";
import { installCommand } from "@/lib/site";

export const revalidate = 300;

const FEATURES: { icon: ReactNode; title: string; body: string }[] = [
  {
    icon: <BellRing className="size-5" />,
    title: "Know the moment it's done",
    body: "A notification when Claude finishes a reply, needs your input or a session closes. Turn each kind on or off, or mute a project.",
  },
  {
    icon: <ListChecks className="size-5" />,
    title: "Answer prompts from anywhere",
    body: "Allow, deny or always allow a command, pick an answer to Claude's questions and approve plans, right from the notification. The first answer wins, phone or PC.",
  },
  {
    icon: <MessagesSquare className="size-5" />,
    title: "Read every session",
    body: "Each Claude Code session's chat on your phone: your prompts, Claude's replies in Markdown and its tool calls, updated as it works.",
  },
  {
    icon: <Reply className="size-5" />,
    title: "Keep Claude working",
    body: "Send the next message from your phone. If Claude is busy, it is queued and delivered when the current reply ends.",
  },
  {
    icon: <PanelTop className="size-5" />,
    title: "A bell on your desktop",
    body: "In the macOS menu bar or the Linux tray: service status, connected phones, your sessions and a QR code to pair a new phone.",
  },
  {
    icon: <ShieldCheck className="size-5" />,
    title: "Stays on your network",
    body: "Your phone talks straight to your computer over Wi-Fi with a TLS certificate pinned at pairing. No cloud, no account, no tracking.",
  },
];

const STEPS: { icon: ReactNode; title: string; body: string }[] = [
  {
    icon: <Bell className="size-5" />,
    title: "Install on your computer",
    body: "One command sets up a small background service, the Claude Code hooks and the bell.",
  },
  {
    icon: <QrCode className="size-5" />,
    title: "Pair your phone",
    body: "Install the app, open the bell's menu and scan the QR code. Pair as many phones and computers as you like.",
  },
  {
    icon: <Wifi className="size-5" />,
    title: "Walk away",
    body: "Claude Code in the terminal, VS Code, JetBrains or the Claude desktop app now reaches you anywhere on your Wi-Fi.",
  },
];

const FAQ: { q: string; a: ReactNode }[] = [
  {
    q: "Does my code or chat leave my network?",
    a: "No. The phone connects directly to your computer over your local network, encrypted with TLS and a certificate pinned when you pair. There is no server in between; this website only hosts the downloads.",
  },
  {
    q: "Which Claude Code setups work?",
    a: "Anything that runs Claude Code on your computer: the terminal, the VS Code and JetBrains extensions, and the Code tab of the Claude desktop app. Cloud sessions run elsewhere and are not covered.",
  },
  {
    q: "My phone can't connect.",
    a: (
      <>
        Phone and computer must be on the same network; guest Wi-Fi and routers with
        &ldquo;client isolation&rdquo; block it. If a firewall is on, allow TCP port 47821: on
        Linux <code className="text-stone-200">sudo ufw allow 47821/tcp</code>, on macOS allow{" "}
        <code className="text-stone-200">mewo</code> in System Settings → Network → Firewall.
      </>
    ),
  },
  {
    q: "I don't see the bell on Linux.",
    a: (
      <>
        GNOME needs the &ldquo;AppIndicator and KStatusNotifierItem Support&rdquo; extension
        (Ubuntu ships it). KDE, Xfce, Cinnamon and most other desktops show it as is. You can
        also start it by hand with <code className="text-stone-200">mewo tray</code>.
      </>
    ),
  },
  {
    q: "macOS says the app is from an unidentified developer.",
    a: (
      <>
        The builds are not notarized yet. Install with the Terminal command, which avoids the
        warning, or run{" "}
        <code className="text-stone-200">xattr -dr com.apple.quarantine mewo mewo-on-fire.app</code>{" "}
        on a manual download.
      </>
    ),
  },
  {
    q: "How do I uninstall it?",
    a: (
      <>
        Run <code className="text-stone-200">mewo uninstall</code>. It removes the hooks, the
        background service and the bell, and keeps your pairings in case you come back.
      </>
    ),
  },
];

function Section({
  id,
  eyebrow,
  title,
  children,
}: {
  id?: string;
  eyebrow: string;
  title: string;
  children: ReactNode;
}) {
  return (
    <section id={id} className="mx-auto w-full max-w-6xl scroll-mt-20 px-4 py-20 sm:px-6 sm:py-28">
      <p className="mb-3 text-sm font-medium text-accent">{eyebrow}</p>
      <h2 className="mb-12 max-w-2xl text-3xl font-semibold tracking-tight text-white sm:text-4xl">
        {title}
      </h2>
      {children}
    </section>
  );
}

export default async function Home() {
  const release = await getLatestRelease();
  const command = installCommand();
  const sizes = Object.fromEntries((release?.assets ?? []).map((a) => [a.name, a.size]));

  return (
    <>
      <header className="sticky top-0 z-50 border-b border-line bg-[#0c0a09]/80 backdrop-blur-lg">
        <div className="mx-auto flex h-16 w-full max-w-6xl items-center justify-between px-4 sm:px-6">
          <a href="#" className="flex items-center gap-2.5 font-semibold text-white">
            <span className="flex size-8 items-center justify-center rounded-lg bg-surface-raised ring-1 ring-line">
              <Bell className="size-4 fill-accent text-accent" />
            </span>
            Mewo on Fire
          </a>
          <nav className="flex items-center gap-1 text-sm text-stone-400">
            <a href="#features" className="hidden rounded-lg px-3 py-2 transition hover:text-white sm:block">
              Features
            </a>
            <a href="#how" className="hidden rounded-lg px-3 py-2 transition hover:text-white sm:block">
              How it works
            </a>
            <a href="#faq" className="hidden rounded-lg px-3 py-2 transition hover:text-white sm:block">
              FAQ
            </a>
            <a
              href="#download"
              className="ml-2 rounded-lg bg-white px-3.5 py-2 font-medium text-stone-950 transition hover:bg-accent-soft"
            >
              Download
            </a>
          </nav>
        </div>
      </header>

      <main className="flex-1">
        {/* Hero */}
        <div className="relative overflow-hidden">
          <div className="bg-grid pointer-events-none absolute inset-0 -z-10" />
          <div className="mx-auto grid w-full max-w-6xl items-center gap-16 px-4 pb-16 pt-16 sm:px-6 sm:pt-24 lg:grid-cols-[1.05fr_1fr]">
            <div>
              <p className="mb-6 inline-flex items-center gap-2 rounded-full border border-line bg-surface px-3 py-1 text-xs text-stone-400">
                <span className="size-1.5 rounded-full bg-accent" />
                {release ? `${release.tag} is out` : "Free"} · macOS · Linux · Android
              </p>
              <h1 className="text-4xl font-semibold leading-[1.05] tracking-tight text-white sm:text-6xl">
                Claude Code,
                <br />
                <span className="text-accent">in your pocket.</span>
              </h1>
              <p className="mt-6 max-w-xl text-lg leading-8 text-stone-400">
                Get a phone notification the moment Claude Code finishes or needs you. Approve
                commands, answer questions and keep sessions going from your phone, over your own
                Wi-Fi.
              </p>
              <div className="mt-10 max-w-xl">
                <HeroActions command={command} />
              </div>
              <p className="mt-6 flex items-center gap-2 text-xs text-stone-500">
                <Lock className="size-3.5" />
                No cloud. No account. Everything stays on your network.
              </p>
            </div>
            <HeroVisual />
          </div>
        </div>

        <Section id="features" eyebrow="Features" title="Step away from your desk without stopping Claude.">
          <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
            {FEATURES.map((f) => (
              <div
                key={f.title}
                className="rounded-2xl border border-line bg-surface p-6 transition hover:border-accent/30"
              >
                <span className="mb-5 flex size-10 items-center justify-center rounded-xl bg-accent/10 text-accent ring-1 ring-accent/20">
                  {f.icon}
                </span>
                <h3 className="mb-2 font-medium text-white">{f.title}</h3>
                <p className="text-sm leading-6 text-stone-400">{f.body}</p>
              </div>
            ))}
          </div>
        </Section>

        <Section id="how" eyebrow="How it works" title="Set up in two minutes.">
          <ol className="grid gap-4 md:grid-cols-3">
            {STEPS.map((s, i) => (
              <li key={s.title} className="relative rounded-2xl border border-line bg-surface p-6">
                <span className="absolute right-6 top-5 font-mono text-4xl font-semibold text-white/5">
                  0{i + 1}
                </span>
                <span className="mb-5 flex size-10 items-center justify-center rounded-xl bg-white/5 text-stone-200 ring-1 ring-line">
                  {s.icon}
                </span>
                <h3 className="mb-2 font-medium text-white">{s.title}</h3>
                <p className="text-sm leading-6 text-stone-400">{s.body}</p>
              </li>
            ))}
          </ol>
          <div className="no-scrollbar mt-6 flex items-center gap-3 overflow-x-auto rounded-2xl border border-line bg-surface px-6 py-5 font-mono text-xs text-stone-400">
            {["Claude Code", "hook", "Mewo on Fire on your computer", "Wi-Fi · pinned TLS", "Mewo on Fire on your phone"].map(
              (part, i) => (
                <span key={part} className="flex shrink-0 items-center gap-3">
                  {i > 0 && <span className="text-accent">→</span>}
                  <span className={i % 2 === 1 ? "text-stone-500" : "rounded-lg bg-white/5 px-2.5 py-1.5 text-stone-200"}>
                    {part}
                  </span>
                </span>
              ),
            )}
          </div>
        </Section>

        <Section id="download" eyebrow="Download" title="Install Mewo on Fire on your computer and your phone.">
          <DownloadTabs command={command} sizes={sizes} />
          {release && (
            <p className="mt-4 text-xs text-stone-500">
              Latest release {release.tag}, published{" "}
              {new Date(release.publishedAt).toLocaleDateString("en-US", {
                year: "numeric",
                month: "long",
                day: "numeric",
              })}
              .
            </p>
          )}
        </Section>

        <Section id="faq" eyebrow="FAQ" title="Questions">
          <div className="divide-y divide-line rounded-2xl border border-line bg-surface">
            {FAQ.map((item) => (
              <details key={item.q} className="group px-6 py-5">
                <summary className="flex cursor-pointer list-none items-center justify-between gap-4 font-medium text-white">
                  {item.q}
                  <span className="text-xl leading-none text-stone-500 transition group-open:rotate-45">+</span>
                </summary>
                <div className="mt-3 max-w-3xl text-sm leading-6 text-stone-400">{item.a}</div>
              </details>
            ))}
          </div>
        </Section>
      </main>

      <footer className="border-t border-line">
        <div className="mx-auto flex w-full max-w-6xl flex-col gap-2 px-4 py-8 text-xs text-stone-500 sm:flex-row sm:items-center sm:justify-between sm:px-6">
          <p className="flex items-center gap-2">
            <Bell className="size-3.5 fill-accent text-accent" />
            Mewo on Fire: Claude Code notifications on your phone
          </p>
          <p>Not affiliated with Anthropic. Claude is a trademark of Anthropic.</p>
        </div>
      </footer>
    </>
  );
}
