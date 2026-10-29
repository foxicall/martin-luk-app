# 產業分類整合

Flutter 啟動時載入 `assets/data/stock_industries.json`，完成後才建立 App 與啟動掃描。載入失敗會顯示重試按鈕。資料索引僅保留於記憶體，不另存可能過期的 SharedPreferences 副本；更新隨 Web/APK 的新資源包提供。

查詢使用市場及完整交易所代碼；不存在或 Unknown 的資料不會推測為已分類。候選股卡片顯示 sector、industry 與 themes。直接行情掃描的候選股 sector 會進入原有候選股序列化流程。雲端 Leader Scanner 的 compact 結果與恢復續掃快取會附加分類來源、日期、狀態及主題；分類不改變 RS 排名、完整分母或進場證據。

## 驗證與 Web 成品

```sh
flutter pub get
flutter analyze
flutter test
node --test --test-isolation=none momentum-cloud/tests/*.test.mjs
flutter build web --release --dart-define=USE_MOCK_DATA=false
cmp assets/data/stock_industries.json build/web/assets/assets/data/stock_industries.json
```

`Verify Flutter and build PWA` 工作流在 main 更新後執行驗證，並提供 `martin-luk-pwa` 成品。它不會部署到其他主機。

目前使用者提供的站點為 https://martin-momentum-lab-20261021.brainysky.chatgpt.site/ 。此儲存庫沒有該站的部署設定，直接 HTTP 讀取回傳 401。推送 GitHub main 不能當成該站已發布的證據；該主機仍需以其既有部署流程載入 Web 成品並驗證更新。未另建 GitHub Pages，以避免產生不同的 App 網址。
