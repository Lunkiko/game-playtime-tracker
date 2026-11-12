# Game Playtime Tracker

背景常駐的 Windows 小工具,自動記錄你玩遊戲的時數。沒有資料庫,紀錄存成CSV文字檔,放在你自己的電腦上。

目前會自動偵測:
- `games.json` 裡列出的遊戲(預設是英雄聯盟LOL / 特戰英豪VALORANT,可在設定裡改)
- 任何在跑的 Steam 遊戲(免設定,自動抓)

## 安裝 / 第一次啟動


- `logs/yyyy-MM.csv`:實際的遊戲時數紀錄,一個月一個檔案
- `games.json`:你設定的遊戲清單
- `settings.json`:你調整過的設定(沒改過設定前不會有這個檔案)
