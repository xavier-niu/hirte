<p align="center"><img src="assets/logo.svg" width="112" height="112" alt=""></p>

<h1 align="center">Hirte</h1>

<p align="center">
  Your terminals and coding agents, in your pocket.<br>
  An iPhone client for <a href="https://github.com/herdrdev/herdr">herdr</a>, made for the iPhone Duo.
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/4TTMAnRM">Join the TestFlight beta</a> ·
  <a href="https://hirte.dev">Website</a> ·
  <a href="#building">Build it yourself</a>
</p>

<p align="center">
  <a href="assets/demo.mp4"><img src="assets/demo.gif" width="640" alt="Hirte on the unfolded iPhone Duo: the terminal list next to an agent, answering it with Yes, then a shell"></a>
</p>

Hirte ("shepherd" in German) connects to your machines over SSH and shows every terminal that
herdr-core runs there: what each agent is doing, which ones are waiting for you, and a real terminal
to jump in when they are.

- **Everything at a glance**: terminals grouped by herdr spaces and tabs, agents under the shell that
  started them, progress, and the ones that need you first
- **A real terminal**, powered by [Ghostty](https://ghostty.org)'s libghostty-vt: key bar, hardware
  keyboards, selection, links, scrollback and pinch to zoom
- **Answer in one tap**: Yes, No, Return or Esc for a blocked agent
- **Keys in the Secure Enclave**, optionally behind Face ID, or a password in the Keychain; host keys
  checked on every connect
- **Themes**: separate light and dark terminal themes, and a choice of fonts

Unfolded on the iPhone Duo, the terminal list and a terminal sit side by side. It works on every
iPhone with iOS 27.1 or later.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/screenshot-dark.png">
    <img src="assets/screenshot-light.png" width="700" alt="Hirte on the unfolded iPhone Duo: the terminal list next to an agent asking to run a database migration, with Yes, No, Return and Esc buttons">
  </picture>
</p>

> Hirte is an independent project. It is not affiliated with or endorsed by the herdr project; it
> speaks herdr-core's public protocol.

## Building

You need a Mac with Xcode 27, [`just`](https://github.com/casey/just),
[`xcbeautify`](https://github.com/cpisciotta/xcbeautify) and [pixi](https://pixi.sh) (for the Zig
compiler that builds libghostty-vt).

```sh
git clone --recurse-submodules https://github.com/glattziehen/hirte
cd hirte
just ghostty   # builds libghostty-vt into HerdrKit/Frameworks
just sim       # runs the app in the simulator
just test      # HerdrKit tests
```

To run it on your own iPhone, sign with your team: set `HIRTE_TEAM` and `HIRTE_BUNDLE_ID_PREFIX`
in `.envrc.local` (see `.envrc`), then `just phone`. `just` lists the other commands.

## License

Apache-2.0, see [LICENSE](LICENSE). Hirte ships Ghostty (libghostty-vt), Citadel, SwiftNIO and
other open-source code, the JetBrains Mono and Comic Mono fonts, and themes from
iTerm2-Color-Schemes; their licenses are in the app under Settings → Open-Source Licenses.
