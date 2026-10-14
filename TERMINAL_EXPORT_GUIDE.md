# 不需下載連結的 HTML／ZIP 匯出

`standalone_preview.html` 是獨立離線示範：所有 CSS、JavaScript、台美股 Mock、持股診斷與計算機都在同一檔案內，不需要 Flutter、Android SDK、後端或 Web 伺服器。完整 Flutter／Python 專案則可交由 GitHub Actions 建置 Android APK。

## 直接複製 HTML

在目前環境終端執行：

```bash
bash /workspace/martin_luk_app/scripts/export_upload.sh --print-html
```

從 `<!doctype html>` 到最後的 `</html>` 全部複製，貼入純文字編輯器，以 UTF-8 儲存為 `standalone_preview.html`，再用 Chrome／Safari／Edge 開啟。瀏覽器顯示的是 Mock 示範行情；修改市價／收盤資料即可測試建議變化。iOS「檔案」的 Quick Look 可能不執行 JavaScript，請使用實際瀏覽器開啟。

若終端會截斷長輸出，不要複製截斷結果。可依序讀取行號範圍，在本機依序接續貼入同一檔案：

```bash
wc -l /workspace/martin_luk_app/standalone_preview.html
sed -n '1,200p' /workspace/martin_luk_app/standalone_preview.html
sed -n '201,400p' /workspace/martin_luk_app/standalone_preview.html
# 繼續 401,600 等範圍，直到最後一行；範圍不要重複或跳過。
```

## 打包 ZIP 與 Base64

本次指定檔名的一鍵成品：

```bash
bash /workspace/martin_luk_app/scripts/package_trading_app.sh
```

輸出 `/workspace/martin_luk_trading_app.zip`、`.zip.b64`、`.zip.sha256`；下方匯出與還原方式相同，只需將 `martin_luk_app_upload.zip` 換成 `martin_luk_trading_app.zip`。也可加 `--print-base64` 或 `--print-html` 印出內容。

以下指令不會下載 SDK、不會連線網路，也不會把巨大 Base64 自動灌入終端：

```bash
bash /workspace/martin_luk_app/scripts/export_upload.sh
```

它會驗證來源、生成逐檔 SHA256 清單、建立 ZIP、檢查 ZIP CRC 與清單一致性，並產出：

```text
/workspace/martin_luk_app_upload.zip
/workspace/martin_luk_app_upload.zip.b64
/workspace/martin_luk_app_upload.zip.sha256
```

ZIP 解壓後 `pubspec.yaml`、`lib/`、`android/`、`.github/` 位於專案根目錄。排除的是 `.git/`、`build/`、`.dart_tool/` 等完整目錄及快取／本機私密設定。請勿使用 `"*.git*"` 或 `"*build*"` 作排除條件：它們會誤刪 `.github/workflows/build_apk.yml` 和 `scripts/build_android.sh`，導致無法雲端建置。

若無法取得 ZIP 下載連結，改把 Base64 搬到本機。可執行：

```bash
bash /workspace/martin_luk_app/scripts/export_upload.sh --print-base64
```

只複製 `BEGIN` 與 `END` 標籤之間的編碼行，存成 `martin_luk_app_upload.zip.b64`。如果長輸出被截斷，讀取已生成的檔案分段複製，避免重新打包使驗證碼改變：

```bash
wc -l /workspace/martin_luk_app_upload.zip.b64
sed -n '1,200p' /workspace/martin_luk_app_upload.zip.b64
sed -n '201,400p' /workspace/martin_luk_app_upload.zip.b64
# 繼續所有行；在本機按順序接續貼入，不包含 sed 指令、提示符或標籤。
cat /workspace/martin_luk_app_upload.zip.sha256
```

Base64 會比 ZIP 多約三分之一體積，完整內容通常有數千行，沒有只貼少量片段就能重建整個專案的方法。務必保留匯出時的 SHA256，還原後核對。

## Linux／macOS 本機還原

可在本機終端用 here-document 貼上完整編碼，或用文字編輯器建立同名檔案：

```bash
cat > martin_luk_app_upload.zip.b64 <<'BASE64'
# 用真正的完整 Base64 替換這一行，不要保留註解或標籤。
BASE64
python3 - <<'PY'
import base64, hashlib
from pathlib import Path
source = Path('martin_luk_app_upload.zip.b64').read_bytes()
encoded = b''.join(source.split())
archive = base64.b64decode(encoded, validate=True)
expected = '把匯出時的64位SHA256貼在這裡'
actual = hashlib.sha256(archive).hexdigest()
if actual != expected.lower():
    raise SystemExit(f'SHA256 不一致：{actual}')
target = Path('martin_luk_app_upload.zip')
with target.open('xb') as handle:
    handle.write(archive)
print(f'PASS {actual}  {target}')
PY
unzip -t martin_luk_app_upload.zip
mkdir martin_luk_app
unzip martin_luk_app_upload.zip -d martin_luk_app
```

若已能取得 `scripts/recover_upload.py` 原始碼，可用較完整的標準函式庫驗證器（SHA256、CRC、不安全路徑、重複檔案、符號連結）還原；它不會自動解壓：

```bash
python3 scripts/recover_upload.py martin_luk_app_upload.zip.b64 \
  --output martin_luk_app_upload.zip --sha256 這裡替換完整64位驗證碼
```

預設拒絕覆寫既有 ZIP；確認後可加 `--force`。此腳本只接受純 Base64 與空白，貼入 `BEGIN/END` 標籤、遺漏行、驗證碼不一致都會報錯。

## Windows PowerShell 本機還原

將編碼存為 UTF-8／ASCII 的 `martin_luk_app_upload.zip.b64`，在同一目錄執行：

```powershell
$encoded = (Get-Content -Raw .\martin_luk_app_upload.zip.b64) -replace '\s', ''
$bytes = [Convert]::FromBase64String($encoded)
$expected = '把匯出時的64位SHA256貼在這裡'
$hasher = [Security.Cryptography.SHA256]::Create()
try { $actual = ([BitConverter]::ToString($hasher.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
finally { $hasher.Dispose() }
if ($actual -ne $expected.ToLowerInvariant()) { throw "SHA256 不一致：$actual" }
if (Test-Path .\martin_luk_app_upload.zip) { throw 'ZIP 已存在，請先確認檔案' }
[IO.File]::WriteAllBytes((Join-Path $PWD 'martin_luk_app_upload.zip'), $bytes)
Expand-Archive .\martin_luk_app_upload.zip -DestinationPath .\martin_luk_app
```

## Push 到 GitHub 並取得 APK

在解壓後包含 `pubspec.yaml` 的根目錄操作，勿將整個專案再套一層子目錄。`.github/workflows/build_apk.yml` 是必要的隱藏目錄內容，使用 Git CLI 能正常提交：

```bash
cd martin_luk_app
git init
git branch -M main
git add .
git commit -m "Add Martin Luk app and offline preview"
git remote add origin https://github.com/你的帳號/你的空白儲存庫.git
git push -u origin main
```

以上 Push 是給使用者在本機執行的操作，本交付不會自動上傳至外部帳號。在 GitHub 的 **Actions** 頁選擇 **Build APK and Web Preview**，如需手動建置，按 **Run workflow** → 選 `main` → **Run workflow**。建置成功後，在該次執行底部 **Artifacts** 下載 `martin-luk-release-apk`，解壓取得 `app-release.apk` 並傳到 Android 手機安裝。產物保留 14 天。

工作流使用 Java 17、指定穩定 Flutter、Android SDK，自動還原官方 Gradle wrapper，執行 `flutter pub get`、分析、測試、Release APK 建置及上傳。Release 示範使用 CI debug keystore 簽署，可安裝測試；正式商店發佈請配置自己的長期簽章。GitHub 設定、網路下載和套件服務可影響執行結果，首次建置以 Actions 日誌為準。

更多 Android／後端說明請見 `README_HOW_TO_BUILD.md`；檔案完整性清單位於 `FILE_MANIFEST.json`。
