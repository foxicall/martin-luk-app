# 台股官方名單逾時備援與續掃說明

2026-10-16（台北時間），版本 **1.4.3+10**。

## 這次截圖的判讀

截圖顯示已嘗試 30/1979 檔、成功評估 30 檔、下一檔為 1268.TWO。使用者已確認下拉後累積會增加到 60 或更多，表示逐頁續掃正常。明確失敗的是 TWSE 上市公司名單請求；上市身分沿用內建字典，不等於 30 檔行情評估全部失敗。

本次補強官方名單的取得路徑，不重設輪掃、不更動選股門檻、不以假行情補足推薦。

## 官方來源與時限

| 市場 | 優先 JSON | JSON 失敗後的官方 CSV |
|---|---|---|
| 上市 | `https://openapi.twse.com.tw/v1/opendata/t187ap03_L` | `https://mopsfin.twse.com.tw/opendata/t187ap03_L.csv` |
| 上櫃 | `https://www.tpex.org.tw/openapi/v1/mopsfin_t187ap03_O` | `https://mopsfin.twse.com.tw/opendata/t187ap03_O.csv` |

備援連結來自政府資料開放平臺：[上市公司基本資料](https://data.gov.tw/dataset/18419)、[上櫃公司基本資料](https://data.gov.tw/dataset/25036)。官方目錄標示上市每月更新、上櫃每日更新；這不保證某次手機請求一定成功，也不保證每筆資料包含當日所有掛牌異動。

每個交易所的 JSON 與 CSV 共用一個單調時鐘期限，包含等待 HTTP 並行額度。JSON 最多使用一半，CSV 只使用剩餘時間；手機原有 4 秒名單請求預算不因備援變成兩次 4 秒，一般服務預設上限仍為 8 秒。成功 JSON 不再要求 CSV。

CSV 為純 Dart 解析，不增加套件：嚴格 UTF-8、BOM、引號與逗號／換行欄位、欄位數、大小、公司代號與出表日期檢查。HTML 錯誤頁、無效日期或格式均會被拒絕。沿用四位數普通股保守分類、排除 91 開頭 TDR 等，上市 `.TW`、上櫃 `.TWO`；發行公司清單不是逐筆 CFI 認證。

原始 `出表日期` 轉為台北日期保存；多日期時取最舊日期。上市 CSV 最長接受 45 個日曆日、上櫃 7 日，這是本程式依來源更新頻率制定的保存策略。既有 JSON／舊格式快取仍維持原先 30 天上限。兩個交易所各自保存日期與取得時間；同伴更新不能延長失敗交易所的原始日期。未取得可用官方來源或有效快取時，仍明確標示內建身分字典，不宣稱最新完整名單。

合併快取需符合各交易所來源、期限及成員聯集，才可免請求重用。含內建身分字典而無完整來源證據的部分快照不會直接命中合併快取；需要重新載入名單時會再試官方來源，有效的個別交易所快取仍保留。進行中的固定名單輪掃不會因此逐頁重新請求名單。

## 覆蓋與安裝

1. 下載並解壓 `martin_luk_tw_official_csv_updates_20261016.zip`；每個檔案都是可直接覆蓋的完整內容，清單見 `UPDATE_FILES.txt`。
2. 在 GitHub `foxicall/martin-luk-app` 切換 `fix/refresh-live-gate-20261014`，依包內相對路徑上傳／覆蓋。不要只上傳 ZIP，也不要多套一層資料夾；務必保留 `.github/` 隱藏目錄。
3. 確認 `pubspec.yaml` 為 `1.4.3+10`。新增 parser、兩個測試檔和工作流必須一起提交。
4. 等最後一次提交的 Actions 成功，下載 `martin-luk-app-release`，解壓後安裝 APK。不要只重跑舊提交。
5. 設定關閉 Mock、選手機直接連線、開啟前台自動更新。下拉後查看累積已嘗試數與下一檔；無須清除資料或重新安裝來重設進度。

不確定之前覆蓋是否完整時，使用完整專案 `martin_luk_tw_official_csv_20261016.zip` 合併覆蓋。

## 為何更新後可能仍看到原本的來源提示

為防止名單忽大忽小而重掃第一頁，進行中的一輪固定成員與建立時的來源提示。更新 APK 不會為了重新讀名單而清除這一輪；官方 CSV 備援在下一次需要載入名單時生效，通常是這一輪完成後。不要把保留的來源提示當成當前每一筆行情都失敗；行情時間以各卡片為準，進度以上方累積數為準。

每次最多 30 檔、每批最多 5 檔，失敗也計入已嘗試並繼續。1979 檔約 66 頁；若每分鐘推進一頁，第一頁後約需 65 分鐘，請求逾時／較小頁面可能更久。手動下拉也可推進；退到背景暫停，下次前台續掃。不會把跨頁不同時間的 RS 假裝成全市場同步排名。零推薦仍是合法結果。

## 驗證與限制

CI 新增：

```bash
flutter test test/tw_issuer_csv_test.dart test/tw_official_fallback_test.dart test/tw_universe_stability_test.dart test/tw_universe_resume_integration_test.dart --dart-define=USE_MOCK_DATA=false --timeout=60s --reporter=expanded
```

測試涵蓋 CSV 編碼／引號／日期、HTTP 錯誤／逾時備援、共享期限、個別來源保存、月名單與日名單有效期、晚到回應與關閉，以及原有 1979 名單跨重啟 30→60→90 續掃。這些 fixture 測試不是最新行情證據；原有真實行情與指標門禁保留，允許零推薦，通過後才編譯 APK。

已讀取 GitHub 基線 run [38852597488](https://github.com/foxicall/martin-luk-app/actions/runs/38852597488)，commit `13e4cb1560b9f3a30bd2b720f173622c970aad25`：1.4.2+9 的續掃測試、真實行情門禁與 APK 建置成功。這不代表新增 CSV 版本已通過。

本環境缺少 Flutter／Dart／Android SDK；本次 Dart 命令因 `flutter: command not found` 退出 127。沙箱阻止直接連線讀取 CSV，僅確認官方目錄及端點身分，未完成原始 CSV bytes、Android 備援連通性或新 APK 實測。請以新提交的 Actions 和手機來源提示確認本版結果；不保證公開端點永遠可用。
