import { Bell, Wifi } from "lucide-react";

const SESSIONS = [
  { name: "mewo-on-fire", state: "Needs you", dot: "bg-amber-400" },
  { name: "web", state: "Working", dot: "bg-sky-400 animate-pulse" },
  { name: "api-server", state: "Finished · 2m ago", dot: "bg-emerald-400" },
];

function BellMark({ className = "" }: { className?: string }) {
  return (
    <span className={`relative inline-flex ${className}`}>
      <Bell className="size-full fill-accent text-accent" />
      <span className="absolute -right-0.5 -top-0.5 size-1.5 rounded-full bg-red-500 ring-2 ring-[#1c1917]" />
    </span>
  );
}

/** A desktop with the bell menu open, and a phone with two notifications. */
export function HeroVisual() {
  return (
    <div className="relative mx-auto w-full max-w-[540px] pb-28 lg:pb-16" aria-hidden>
      <div className="absolute -inset-10 -z-10 rounded-full bg-accent/15 blur-3xl" />

      {/* Desktop */}
      <div className="overflow-hidden rounded-2xl border border-line bg-surface shadow-2xl shadow-black/60">
        <div className="flex items-center justify-between border-b border-line bg-surface-raised px-4 py-2 text-[11px] text-stone-400">
          <div className="flex items-center gap-1.5">
            <span className="size-2.5 rounded-full bg-[#ff5f57]" />
            <span className="size-2.5 rounded-full bg-[#febc2e]" />
            <span className="size-2.5 rounded-full bg-[#28c840]" />
          </div>
          <div className="flex items-center gap-3">
            <Wifi className="size-3.5" />
            <span className="rounded bg-white/10 p-0.5">
              <BellMark className="size-3.5" />
            </span>
            <span>9:41</span>
          </div>
        </div>

        <div className="relative h-72 bg-black/40 p-5 font-mono text-[11px] leading-5 text-stone-500">
          <p>
            <span className="text-accent">❯</span> claude
          </p>
          <p className="text-stone-400">● Update the release workflow and the docs</p>
          <p>⎿ Edited .github/workflows/release.yml</p>
          <p>⎿ Edited pc/README.md</p>
          <p className="text-stone-400">● Run the build?</p>

          {/* The bell's menu */}
          <div className="absolute right-3 top-2 w-64 rounded-xl border border-white/10 bg-[#211e1c]/95 p-2 font-sans shadow-xl shadow-black/50 backdrop-blur">
            <div className="flex items-center gap-2.5 px-2 py-1.5">
              <span className="size-2 rounded-full bg-emerald-400" />
              <div className="min-w-0">
                <p className="text-[12px] font-medium text-stone-100">studio-mac</p>
                <p className="text-[10.5px] text-stone-400">192.168.1.20 · 1 phone connected</p>
              </div>
            </div>
            <div className="my-1.5 h-px bg-white/10" />
            <p className="px-2 pb-1 text-[10px] uppercase tracking-wider text-stone-500">Sessions</p>
            {SESSIONS.map((s) => (
              <div
                key={s.name}
                className="flex items-center gap-2.5 rounded-md px-2 py-1.5 text-[11.5px] first:bg-white/5"
              >
                <span className={`size-1.5 rounded-full ${s.dot}`} />
                <span className="flex-1 text-stone-200">{s.name}</span>
                <span className="text-stone-500">{s.state}</span>
              </div>
            ))}
            <div className="my-1.5 h-px bg-white/10" />
            <p className="px-2 py-1 text-[11.5px] text-stone-300">Pair a Phone…</p>
            <p className="px-2 py-1 text-[11.5px] text-stone-300">Send Test Notification</p>
          </div>
        </div>
      </div>

      {/* Phone */}
      <div className="absolute -bottom-2 left-2 w-[232px] rounded-[2.4rem] border border-white/15 bg-black p-2.5 shadow-2xl shadow-black/70 sm:-left-8">
        <div className="rounded-[1.9rem] bg-gradient-to-b from-[#2a211d] to-[#120f0d] px-3 pb-4 pt-3">
          <div className="mx-auto mb-3 h-4 w-16 rounded-full bg-black" />
          <p className="text-center text-3xl font-light tracking-tight text-white/90">9:41</p>
          <p className="mb-4 text-center text-[10px] text-white/50">Wednesday, October 1</p>

          <div className="mb-2 rounded-2xl bg-white/10 p-3 backdrop-blur">
            <div className="mb-1 flex items-center gap-1.5 text-[9.5px] text-white/50">
              <span className="flex size-4 items-center justify-center rounded bg-[#1c1917]">
                <BellMark className="size-2.5" />
              </span>
              Mewo on Fire · now
            </div>
            <p className="text-[11px] font-semibold text-white">Claude needs your permission</p>
            <p className="text-[10.5px] text-white/70">mewo-on-fire · Bash: npm run build</p>
            <div className="mt-2 grid grid-cols-3 gap-1 text-center text-[10px] font-medium">
              <span className="rounded-md bg-accent py-1 text-stone-950">Allow</span>
              <span className="rounded-md bg-white/15 py-1 text-white">Always</span>
              <span className="rounded-md bg-white/15 py-1 text-white">Deny</span>
            </div>
          </div>

          <div className="rounded-2xl bg-white/10 p-3 backdrop-blur">
            <div className="mb-1 flex items-center gap-1.5 text-[9.5px] text-white/50">
              <span className="flex size-4 items-center justify-center rounded bg-[#1c1917]">
                <BellMark className="size-2.5" />
              </span>
              Mewo on Fire · 2m ago
            </div>
            <p className="text-[11px] font-semibold text-white">✅ Claude finished</p>
            <p className="text-[10.5px] text-white/70">api-server · Added pagination to the users endpoint.</p>
            <div className="mt-2 rounded-md bg-white/15 py-1 text-center text-[10px] font-medium text-white">
              Reply
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
