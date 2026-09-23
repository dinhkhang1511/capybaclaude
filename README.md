# 🦖 Dino — Claude Code desktop companion (macOS)

Con dino nổi trên mọi màn hình / Space / app (kể cả Chrome full-screen), hiện bubble
mỗi khi Claude Code chạy xong, cần xác nhận, hoặc lỗi.

## 1. Cài đặt

### Cách nhanh — 1 dòng curl, không cần git clone

```bash
curl -fsSL https://raw.githubusercontent.com/dinhkhang1511/capybaclaude/main/install.sh | bash
```

Thêm `-s -- --hooks` để tự nối vào Claude Code luôn (merge `claude-hooks.json`
vào `~/.claude/settings.json`, có dedupe — chạy lại không bị trùng):

```bash
curl -fsSL https://raw.githubusercontent.com/dinhkhang1511/capybaclaude/main/install.sh | bash -s -- --hooks
```

Cài từ branch khác: `... | bash -s -- --branch maomao`.

**Máy không build được (không có Xcode CLT / swiftc lỗi):** thêm `--prebuilt` để
tải app dựng sẵn (universal Apple Silicon + Intel, macOS 13+), không cần compiler:

```bash
curl -fsSL https://raw.githubusercontent.com/dinhkhang1511/capybaclaude/main/install.sh | bash -s -- --prebuilt
```

(Script cũng tự chuyển sang prebuilt nếu không tìm thấy `swiftc`.)

### Build từ source

```bash
chmod +x build.sh
./build.sh
```

Tạo `~/Applications/Dino.app` (LSUIElement → không có icon Dock, chỉ có 🦖 trên menu bar)
và mở luôn. Cần Xcode Command Line Tools: `xcode-select --install`.

Chạy nhanh không cần bundle:

```bash
swiftc -O main.swift -o dino && ./dino
```

## 2. Nối vào Claude Code

Merge `claude-hooks.json` vào `~/.claude/settings.json` (global, mọi project):

```bash
python3 - <<'EOF'
import json, pathlib
p = pathlib.Path.home()/".claude/settings.json"
s = json.loads(p.read_text()) if p.exists() else {}
add = json.loads(pathlib.Path("claude-hooks.json").read_text())["hooks"]
s.setdefault("hooks", {})
for ev, groups in add.items():
    s["hooks"].setdefault(ev, []).extend(groups)
p.parent.mkdir(exist_ok=True)
p.write_text(json.dumps(s, indent=2))
print("ok →", p)
EOF
```

Mở session mới, gõ `/hooks` để kiểm tra. Xong.

### Event nào → trạng thái nào

| Hook event | Dino |
|---|---|
| `UserPromptSubmit` | ⚙️ working — "Đang chạy…" |
| `Notification` | ✋ waiting + sound `Ping` — cần approve tool / idle 60s |
| `Stop` | ✅ done + sound `Glass` — hiện `last_assistant_message` |
| `StopFailure` | 💥 error + sound `Basso` — rate_limit, overloaded… |
| `SessionEnd` | ẩn bubble |

Đây là **HTTP hooks** (`type: "http"`) — Claude Code POST thẳng JSON payload vào app,
không cần script trung gian, không cần `jq`. Nếu Dino không chạy, connection failure chỉ
là non-blocking error, session của bạn vẫn chạy bình thường.

## 3. Dùng cho việc khác

Endpoint mở cho bất cứ script nào:

```bash
curl -s localhost:7654/notify -d '{
  "state":"done", "title":"deploy", "message":"ai-photo staging đã lên", "ttl":10
}'
```

`state`: `idle` | `working` | `waiting` | `done` | `error`. `ttl` = 0 → giữ mãi tới event kế.

Ví dụ gắn vào build:

```bash
make build && curl -s localhost:7654/notify -d '{"state":"done","message":"build ok"}' \
           || curl -s localhost:7654/notify -d '{"state":"error","message":"build failed"}'
```

## 4. Menu bar 🦖

- **Test bubble** — thử hiển thị
- **Move mode** — bật để kéo dino tự do (tắt click-through), nhớ tắt lại
- **Vị trí** — snap về 1 trong 4 góc
- **Quit**

Mặc định `ignoresMouseEvents = true` nên dino không bao giờ chắn click của bạn.

## 5. Chạy khi khởi động

System Settings → General → Login Items → `+` → `~/Applications/Dino.app`.

## 6. Tuỳ chỉnh

| Muốn gì | Sửa ở đâu |
|---|---|
| Đổi port | env `DINO_PORT=9000` khi launch |
| Đổi sprite | Đặt file `dino.png` cạnh `main.swift` rồi `./build.sh` (hoặc set env `DINO_IMAGE=/path/to/img.png`). Không có file → fallback về emoji 🦖 |
| Sprite khi đang chạy | Đặt GIF `dino-working.gif` cạnh `main.swift` (hoặc env `DINO_WORKING_IMAGE`) — tự play khi state = working, hết working thì về `dino.png` |
| Theo nhạc đang phát | Menu bar → **🎵 Theo nhạc đang phát** (mặc định bật). Pet nhảy khi có tiếng, hiện bubble tên bài khi đổi bài, **click vào pet** = play/pause, **cuộn trên pet** = bài kế/bài trước. Xem mục 7 về quyền |
| Thêm pet mới | Menu bar → **Nhân vật** → **Thêm pet từ link…** → dán link `codex-pets.net/#/pets/<id>` (tự prefill nếu link đang ở clipboard). App tải spritesheet về `~/Library/Application Support/Dino/pets/<id>/`, cắt frame và chuyển sang pet mới luôn — không cần rebuild |
| Zoom sprite | Menu bar → **Kích thước** → Nhỏ 56 / Vừa 80 / Lớn 110 / Bự 150pt (lưu vào UserDefaults) |
| Đổi nhân vật | Menu bar → **Nhân vật** → Capybara / MaoMao / Frieren / Nezuko (lưu vào UserDefaults). MaoMao: idle / review (working) / jumping (done) từ `maomao/*.gif`. Frieren & Nezuko: thêm cả waiting + failed (error) — cắt từ spritesheet của [codex-pets.net](https://codex-pets.net) ([frieren](https://codex-pets.net/#/pets/frieren) by rudoduro, [nezu](https://codex-pets.net/#/pets/nezu) by dc); Nezuko dùng row "running" (gõ laptop) khi working |
| Đổi âm thanh | `DinoState.systemSound` — tên file trong `/System/Library/Sounds` |
| Cắt message ngắn hơn | `AppDelegate.clean()`, hằng `240` |
| Luôn ẩn dino khi idle | `DinoOverlay.dino` → `.opacity(... ? 0 : 1)` |

## 7. Chế độ theo nhạc 🎵

Pet nhảy theo nhạc đang phát, hiện tên bài, và làm remote điều khiển.

| Tính năng | Cơ chế | Quyền cần |
|---|---|---|
| Nhảy khi có nhạc | CoreAudio (`kAudioDevicePropertyDeviceIsRunningSomewhere`) | **Không cần** — nhận mọi nguồn tiếng (Chrome, YouTube, game…) |
| Bubble tên bài | AppleScript hỏi Spotify / Music / tab YouTube của Chrome | Automation (macOS tự hỏi lần đầu) |
| Click = play/pause, cuộn = đổi bài | Media key toàn hệ thống (`NX_KEYTYPE_PLAY/NEXT/PREVIOUS`) | **Accessibility** |

Vài lưu ý:

- **MediaRemote không dùng được.** API "now playing" toàn hệ thống của Apple bị khoá
  sau entitlement từ macOS 15.4, app tự build gọi vào chỉ nhận kết quả rỗng — nên phải
  tách đôi: CoreAudio biết *có đang phát không*, AppleScript biết *đang phát cái gì*.
- **Trạng thái Claude luôn thắng.** Pet chỉ nhảy khi Claude đang rảnh (idle); lúc đang
  chạy / chờ xác nhận / lỗi thì sprite theo trạng thái Claude như cũ.
- **Click-through vẫn giữ.** Panel chỉ nhận chuột khi con trỏ nằm đúng trên pet, nên
  không bao giờ chắn click của bạn.
- Với Chrome, app tìm tab có tiêu đề kết thúc bằng `- YouTube` (ưu tiên tab đang mở).
  Mở nhiều tab YouTube cùng lúc thì tên bài có thể không khớp tab đang kêu.
- **Quyền bị hỏi lại sau mỗi lần build lại:** `build.sh` ký ad-hoc (`codesign --sign -`),
  mỗi lần build ra chữ ký mới → macOS coi như app khác → quyền Accessibility cũ hết
  hiệu lực (dòng cũ trong danh sách vẫn hiện tick nhưng **không còn tác dụng**). Cách xử
  lý: vào System Settings → Privacy & Security → Accessibility, **xoá hết dòng Dino cũ
  bằng nút `–`**, rồi click vào pet để cấp lại. Bản prebuilt (`dist/Dino.app.zip`) giữ
  nguyên binary nên cấp một lần là xong.

## Hạn chế đã biết

- Nhiều session Claude Code cùng lúc → session nào bắn event sau cùng thì thắng.
  Muốn tách riêng thì key theo `session_id` trong payload và render nhiều dino.
- Chỉ hiện trên `NSScreen.main`. Multi-monitor thì chọn góc rồi dùng Move mode.
- Dùng `NSSound` chứ không phải Notification Center (tránh phải sign/notarize app).
