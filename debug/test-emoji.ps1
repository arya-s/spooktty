# Test script for color emoji rendering in PowerShell
# Run: powershell -ExecutionPolicy Bypass -File test-emoji.ps1

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host ""
Write-Host "── Common Emoji ──────────────────────────"
Write-Host "  Faces:    😀 😃 😄 😁 😆 😅 🤣 😂"
Write-Host "  Cool:     😎 🤩 🥳 😏 😒 😞 😔 😟"
Write-Host ""

Write-Host "── Skin Tone Modifiers ───────────────────"
Write-Host "  Wave:     👋 👋🏻 👋🏼 👋🏽 👋🏾 👋🏿"
Write-Host "  Thumb:    👍 👍🏻 👍🏼 👍🏽 👍🏾 👍🏿"
Write-Host ""

Write-Host "── Flags ─────────────────────────────────"
Write-Host "  🇺🇸 🇬🇧 🇩🇪 🇫🇷 🇯🇵 🇨🇳 🇧🇷 🇮🇳 🇦🇹 🇪🇺"
Write-Host ""

Write-Host "── Animals ───────────────────────────────"
Write-Host "  🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯"
Write-Host ""

Write-Host "── Food & Drink ─────────────────────────"
Write-Host "  🍎 🍐 🍊 🍋 🍌 🍉 🍇 🍓 🍒 🍕"
Write-Host ""

Write-Host "── Objects & Symbols ─────────────────────"
Write-Host "  ❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔"
Write-Host "  ⭐ 🌟 ✨ 💫 🎵 🎶 🎯 🎲 🎮"
Write-Host ""

Write-Host "── Emoji in Context ──────────────────────"
Write-Host "  Status:  ✅ Build passed    ❌ Tests failed"
Write-Host "  Hello 👋 World 🌍!"
Write-Host "  Coffee ☕ + Code 💻 = 🚀"
Write-Host ""
