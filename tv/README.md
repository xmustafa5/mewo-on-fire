# Mewo on Fire for Apple TV

The sessions and chats of a paired PC on the big screen: prompts answered with
the remote, messages typed (or dictated) with the Siri Remote's keyboard.
`tv/MewoTV.xcodeproj`, SwiftUI, tvOS 17 or later.

The TV connects to the PC itself, like the phone does (`PROTOCOL.md`): TLS
with the PC's certificate pinned, the device token, then the usual frames.
It needs to be on the PC's network (no relay on the TV).

## Pairing

1. On the PC: `mewo pair` (or `ccnotify pair`). Under the QR code it prints
   the pairing code.
2. On the TV: the app lists the PCs it finds on the network; choose yours (or
   type its address), type the pairing code, **Pair**. The certificate seen
   then is pinned from then on.

## Install on an Apple TV

With Xcode: pair the Apple TV with the Mac once (Device Hub → File → Pair
Nearby Device; on the TV, Settings → Remotes and Devices → Remote App and
Devices), pick your team under Signing & Capabilities, build and run the
`MewoTV` scheme on the TV.
