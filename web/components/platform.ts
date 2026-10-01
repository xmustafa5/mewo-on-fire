"use client";

import { useSyncExternalStore } from "react";

export type Platform = "macos" | "linux" | "android" | "ios" | "windows" | "other";

function detect(): Platform {
  const ua = navigator.userAgent;
  if (/android/i.test(ua)) return "android";
  if (/iphone|ipad|ipod/i.test(ua)) return "ios";
  // iPadOS reports itself as a Mac; only it has a touch screen.
  if (/mac/i.test(ua)) return navigator.maxTouchPoints > 1 ? "ios" : "macos";
  if (/windows/i.test(ua)) return "windows";
  if (/linux|x11|cros/i.test(ua)) return "linux";
  return "other";
}

const subscribe = () => () => {};

/** The visitor's platform; null while rendering on the server. */
export function usePlatform(): Platform | null {
  return useSyncExternalStore(subscribe, detect, () => null);
}
