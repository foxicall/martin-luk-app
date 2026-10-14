# 127.0.0.1 預覽連線問題：診斷與修復

本次在 `/workspace/martin_luk_app` 的實際診斷：沒有 Flutter SDK、沒有 Web 伺服器進程、8080沒有監聽。原啟動腳本只綁127.0.0.1且要求Flutter，所以此環境原本無法啟動。另實測綁定 `0.0.0.0:8080` 被執行沙箱以 `PermissionError: Operation not permitted` 拒絕。

已修正 launcher 預設為 `0.0.0.0:8080`，新增無需Flutter的Mock模式、已有Flutter Web產物模式及 `/__health` 檢查。主機是否允许監聽、平台是否提供埠轉送仍是不同的環境條件；程式碼改好不等於已取得對外網址。

## 在允許監聽服務的環境啟動

不需要任何 SDK 的互動預覽：

```bash
cd /workspace/martin_luk_app
bash scripts/preview_web.sh --mock --host 0.0.0.0 --port 8080
```

成功時必須看到 `LISTEN 0.0.0.0:8080 | mode=mock`。這是自含HTML預覽，可完整操作Mock卡片及風控計算。

Flutter 開發預覽（需要 Flutter SDK）：

```bash
flutter run -d web-server --web-hostname 0.0.0.0 --web-port 8080 \
  --dart-define=USE_MOCK_DATA=true
```

GitHub Actions下載的正式Flutter Web，解壓到 `build/web/` 後，不需要本機Flutter就能提供：

```bash
bash scripts/preview_web.sh --serve-built --host 0.0.0.0 --port 8080
```

## 應開啟哪個網址

| 所在環境 | 瀏覽器入口 |
| --- | --- |
| 程式與瀏覽器在同一台電腦 | `http://127.0.0.1:8080/` |
| Codespaces | **Ports** 加入8080，開啟該列實際提供的Forwarded Address；通常有登入保護 |
| VS Code Remote | **Ports / Forward a Port** 加入8080，使用該列的本機或遠端轉送網址 |
| SSH遠端主機 | 先從您的電腦建立下列SSH tunnel，再開本機127.0.0.1 |
| Docker | 程式在容器內綁0.0.0.0，建立容器時還需發布8080埠，例如 `-p 8080:8080`；瀏覽器連Docker主機或其轉送網址 |
| ChatGPT Work遠端環境 | 使用平台實際提供的Preview／Port Forward URL；本次工具未提供可取得該URL的介面，不可推定您的127.0.0.1能連入 |

SSH轉送應在**您的電腦**執行，將帳號與地址換成實際遠端主機：

```bash
ssh -N -L 8080:127.0.0.1:8080 使用者@遠端主機
```

`0.0.0.0` 是服務監聽位址，不是應填入瀏覽器的遠端主機地址。瀏覽器的127.0.0.1永遠指向瀏覽器所在機器，除非已建立本機埠轉送。

## 分層檢查

在**啟動服務的同一台機器**另開終端機：

```bash
ss -ltnp 'sport = :8080'
curl --noproxy 127.0.0.1 -f http://127.0.0.1:8080/__health
```

Mock健康檢查應回傳 `{"ok": true, "mode": "mock", "port": 8080}`。標準Flutter開發伺服器沒有這個自訂健康路由，應檢查 `/` 的HTTP回應。

- **沒有LISTEN**：檢查啟動錯誤與終端機是否仍在執行；Flutter模式先确认SDK，缺SDK可使用 `--mock`。
- **顯示Operation not permitted**：是執行沙箱拒絕socket。需要平台授權本機網路監聽，或在您的電腦執行；改Host或換Port不能解除此限制。
- **同機健康檢查成功、您的瀏覽器失敗**：檢查平台埠轉送、是否登入、Docker埠發布及主機防火牆／入站規則。只開所需8080埠，不必關閉整個防火牆。
- **Port已占用**：查明8080被哪個服務使用，再選擇停止自己的舊服務或更換埠；轉送設定必須同步更新。
- **頁面404**：Mock入口是 `/index.html?preview=mock`；正式Web入口是 `/phone_preview.html`，不要在 `web/` 原始碼目錄提供尚未编譯的Flutter檔案。

## 完全避開遠端連線

可下載 `preview/index.html`，在您電腦的Chrome／Edge／Safari直接開啟，點「重設為離線示範」。該HTML自含樣式、Mock資料與風控運算，不需要127.0.0.1、後端、SDK或遠端埠。

## 已完成的驗證與限制

12項啟動參數測試與6項HTTP handler測試通過。測試採替代程序／socket測試替身，不表示跨機HTTP已連通。此環境的實際啟動仍受沙箱socket限制，對外預覽需取得監聽權限及平台埠轉送後再確認。
