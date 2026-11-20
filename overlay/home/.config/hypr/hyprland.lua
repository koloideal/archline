-- Перенесено с hyprland.conf (hyprlang) на Lua, Hyprland >= 0.55
-- https://wiki.hypr.land/Configuring/Start/

local home = os.getenv("HOME")
local hypr = home .. "/.config/hypr"

local function exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

------------------
---- MONITORS ----
------------------

hl.monitor({ output = "", mode = "highrr", position = "auto", scale = 1 })

---------------------
---- MY PROGRAMS ----
---------------------

local terminal    = "kitty"
local fileManager = "thunar"
local menu        = "wofi --show drun --conf " .. hypr .. "/wofi/config.conf --style " .. hypr .. "/wofi/style.css"

-------------------
---- AUTOSTART ----
-------------------

hl.on("hyprland.start", function()
    hl.exec_cmd("nm-applet")
    hl.exec_cmd("gammastep")
    hl.exec_cmd("blueman-applet")
    hl.exec_cmd("udiskie")
    hl.exec_cmd("/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1")
    hl.exec_cmd("waybar -c " .. hypr .. "/waybar/config.jsonc -s " .. hypr .. "/waybar/style.css")
    hl.exec_cmd("swaync -c " .. hypr .. "/swaync/config.json")
    hl.exec_cmd("awww-daemon")
    hl.exec_cmd(home .. "/.local/bin/wallpaper-picker.py --restore")
    hl.exec_cmd(home .. "/.local/bin/wallpaper-picker.py --warm")
    hl.exec_cmd("hypridle")
    hl.exec_cmd("swayosd-server --top-margin 0.85")
    hl.exec_cmd(home .. "/.local/bin/startup-sound.sh")
    hl.exec_cmd("dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP")
    hl.exec_cmd("hyprctl setcursor 'Bibata-Modern-Amber' 24")
    hl.exec_cmd("XDG_MENU_PREFIX=arch- kbuildsycoca6 --noincremental")
    hl.exec_cmd("systemctl --user import-environment QT_QPA_PLATFORMTHEME")
    if exists(home .. "/.local/bin/firstrun.sh") then
        hl.exec_cmd(home .. "/.local/bin/firstrun.sh")
    end
end)

-- Выполняется на каждом reload (как `exec =` в старом конфиге)
hl.exec_cmd("gsettings set org.gnome.desktop.interface gtk-theme 'Gruvbox-Material-Dark'")
hl.exec_cmd("gsettings set org.gnome.desktop.interface icon-theme 'Gruvbox-Plus-Dark'")
hl.exec_cmd("gsettings set org.gnome.desktop.interface cursor-theme 'Bibata-Modern-Amber'")
hl.exec_cmd("gsettings set org.gnome.desktop.input-sources sources \"[('xkb', 'us'),('xkb', 'ru')]\"")
hl.exec_cmd("gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'")

-------------------------------
---- ENVIRONMENT VARIABLES ----
-------------------------------

hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("MOZ_ENABLE_WAYLAND", "1")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "wayland")
hl.env("QT_QPA_PLATFORMTHEME", "qt6ct")
hl.env("TERMINAL", "/usr/bin/kitty")
hl.env("XCURSOR_THEME", "Bibata-Modern-Amber")
hl.env("XCURSOR_SIZE", "24")
hl.env("GTK_USE_PORTAL", "1")

-- Гибрид Intel + NVIDIA: рендер на iGPU, dGPU нужна для HDMI.
-- Симлинки создаёт /etc/udev/rules.d/61-gpu-paths.rules
if exists("/dev/dri/igpu") then
    local devices = "/dev/dri/igpu"
    if exists("/dev/dri/dgpu") then devices = devices .. ":/dev/dri/dgpu" end
    hl.env("AQ_DRM_DEVICES", devices)
end

-----------------------
---- LOOK AND FEEL ----
-----------------------

hl.config({
    general = {
        gaps_in     = 5,
        gaps_out    = 20,
        border_size = 2,
        col = {
            active_border   = { colors = { "rgba(D65D0EEE)", "rgba(458588EE)" }, angle = 45 },
            inactive_border = "rgba(595959aa)",
        },
        layout              = "dwindle",
        allow_tearing       = true,
        resize_on_border    = true,
        hover_icon_on_border = true,
    },

    decoration = {
        rounding = 20,
        blur = {
            enabled           = true,
            size              = 8,
            passes            = 1,
            new_optimizations = true,
        },
        shadow = {
            enabled = false,
        },
    },

    animations = {
        enabled = true,
    },

    dwindle = {
        preserve_split = true,
    },

    master = {
        new_status = "master",
        new_on_top = true,
    },

    xwayland = {
        force_zero_scaling = true,
    },

    gestures = {
        workspace_swipe_touch        = true,
        workspace_swipe_cancel_ratio = 0.15,
    },

    misc = {
        force_default_wallpaper = 0,
        focus_on_activate       = false,
        close_special_on_empty  = true,
    },

    cursor = {
        inactive_timeout = 5,
    },
})

hl.curve("myBezier", { type = "bezier", points = { {0.05, 0.9}, {0.1, 1.05} } })

hl.animation({ leaf = "windows",     enabled = true,  speed = 7,  bezier = "myBezier" })
hl.animation({ leaf = "windowsOut",  enabled = true,  speed = 7,  bezier = "default", style = "popin 80%" })
hl.animation({ leaf = "border",      enabled = false, speed = 10, bezier = "default" })
hl.animation({ leaf = "borderangle", enabled = false, speed = 1,  bezier = "default" })

---------------
---- INPUT ----
---------------

hl.config({
    input = {
        kb_layout  = "us,ru",
        kb_model   = "",
        kb_variant = "",
        kb_options = "grp:caps_toggle",
        kb_rules   = "",

        follow_mouse = 1,
        sensitivity  = 0,

        touchpad = {
            natural_scroll       = false,
            disable_while_typing = true,
            tap_to_click         = true,
            clickfinger_behavior = true,
        },

        touchdevice = {},

        tablet = {},
    },
})

--------------------------------
---- WINDOWS AND WORKSPACES ----
--------------------------------

hl.window_rule({
    name  = "wallpaper-picker-float",
    match = { class = "^(dev.wp.pick)$" },
    float = true,
    center = true,
    size = { "monitor_w*0.45", "monitor_h*0.52" },
})

hl.window_rule({
    name  = "hotkeys-help-float",
    match = { class = "^(hotkeys-help)$" },
    float = true,
    center = true,
    size = { "monitor_w*0.60", "monitor_w*0.60*9/16" },
})

hl.window_rule({
    name  = "suppress-maximize-events",
    match = { class = ".*" },
    suppress_event = "maximize",
})

hl.window_rule({
    name  = "steam-toasts-no-focus",
    match = { class = "^(steam)$", title = "^(notificationtoasts_.*_desktop)$" },
    no_focus = true,
})

hl.window_rule({
    name  = "thunderbird-reminder-center",
    match = { title = "Reminder", class = "^(thunderbird)$" },
    center = true,
})

hl.window_rule({
    name  = "telegram-media-viewer-no-anim",
    match = { initial_title = "^Media viewer$", initial_class = "^org.telegram.desktop$" },
    no_anim = true,
})

---------------------
---- KEYBINDINGS ----
---------------------

local mainMod = "SUPER"

-- Super + F1 — рабочий сетап (раньше scripts/workspace-setup.sh)
hl.bind(mainMod .. " + F1", function()
    -- Workspace 1 — Chrome
    hl.dispatch(hl.dsp.focus({ workspace = 1 }))
    hl.dispatch(hl.dsp.exec_cmd("google-chrome-stable"))
    -- Workspace 2 — Zed
    hl.dispatch(hl.dsp.exec_cmd("zeditor ~/Programming_Projects/Python_Projects/Tunnex/", { workspace = "2 silent" }))
    -- Workspace 3 — Telegram + Kitty
    hl.exec_cmd("pkill -9 Telegram")
    hl.timer(function()
        hl.dispatch(hl.dsp.exec_cmd("/usr/bin/Telegram", { workspace = "3 silent" }))
        hl.dispatch(hl.dsp.exec_cmd("kitty", { workspace = "3 silent" }))
    end, { timeout = 500, type = "oneshot" })
end)

-- --- Core actions ---

hl.bind(mainMod .. " + Return", hl.dsp.exec_cmd(terminal))
-- Super + Enter — открыть терминал

hl.bind(mainMod .. " + N", hl.dsp.exec_cmd("swaync-client --open-panel"))
-- Super + N - открыть уведомления

hl.bind(mainMod .. " + SHIFT + N", hl.dsp.exec_cmd("swaync-client --close-panel"))
-- Super + Shift + N - закрыть уведомления

hl.bind(mainMod .. " + Q", hl.dsp.window.close())
-- Super + Q — закрыть активное окно

hl.bind(mainMod .. " + SHIFT + Q", hl.dsp.exec_cmd("uwsm stop"))
-- Super + Shift + Q — выйти из Hyprland

hl.bind(mainMod .. " + D", hl.dsp.exec_cmd(menu))
-- Super + D — меню приложений

hl.bind(mainMod .. " + H", hl.dsp.exec_cmd(home .. "/.local/bin/toggle-hotkeys-help.sh"))
-- Super + H — справка по хоткеям / закрыть её

hl.bind(mainMod .. " + W", hl.dsp.exec_cmd(home .. "/.local/bin/wallpaper-picker.py"))
-- Super + W — выбор обоев

hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager))
-- Super + E — файловый менеджер

hl.bind(mainMod .. " + Space", hl.dsp.exec_cmd("hyprctl switchxkblayout all next"))
-- Super + Space — переключить раскладку клавиатуры

hl.bind(mainMod .. " + SHIFT + F", hl.dsp.window.fullscreen())
-- Super + Shift + F — полноэкранный режим

hl.bind(mainMod .. " + V", hl.dsp.window.float({ action = "toggle" }))
-- Super + V — переключить окно в плавающее/тайлинг

hl.bind(mainMod .. " + P", hl.dsp.window.pseudo())
-- Super + P — включить/выключить pseudotile

hl.bind(mainMod .. " + S", hl.dsp.workspace.toggle_special("magic"))
-- Super + S — открыть/закрыть scratchpad workspace "magic"

hl.bind(mainMod .. " + SHIFT + S", hl.dsp.window.move({ workspace = "special:magic" }))
-- Super + Shift + S — отправить текущее окно в scratchpad

-- --- Window movement ---

hl.bind(mainMod .. " + L", hl.dsp.exec_cmd("hyprlock"))
hl.bind(mainMod .. " + X", hl.dsp.exec_cmd(home .. "/.local/bin/power-menu.sh"))

local directions = { H = "left", J = "down", K = "up", L = "right" }
for key, dir in pairs(directions) do
    hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ direction = dir }))
end
-- Super + Shift + H/J/K/L — двигать окно влево/вниз/вверх/вправо

for _, dir in ipairs({ "left", "down", "up", "right" }) do
    hl.bind(mainMod .. " + " .. dir, hl.dsp.focus({ direction = dir }))
    hl.bind(mainMod .. " + SHIFT + " .. dir, hl.dsp.window.move({ direction = dir }))
end
-- Super + стрелки — фокус по окнам
-- Super + Shift + стрелки — двигать окно

hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
-- Super + ЛКМ drag — перемещение окна мышью

hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })
-- Super + ПКМ drag — изменение размера окна мышью

-- --- Workspaces ---

for i = 1, 10 do
    local key = i % 10
    hl.bind(mainMod .. " + " .. key, hl.dsp.focus({ workspace = i }))
    hl.bind(mainMod .. " + SHIFT + " .. key, hl.dsp.window.move({ workspace = i }))
end
-- Super + цифра — перейти на workspace
-- Super + Shift + цифра — отправить окно на workspace

hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))
-- Super + scroll — переключать workspace вперёд/назад

-- --- Utilities ---

hl.bind("Print", hl.dsp.exec_cmd("bash -c 'grim - | tee /tmp/screenshot.png | wl-copy'"))
hl.bind("SHIFT + Print", hl.dsp.exec_cmd("bash -c 'slurp | grim -g - - | tee /tmp/screenshot.png | wl-copy'"))
-- Shift + Print — скриншот выделенной области

hl.bind("XF86AudioPlay", hl.dsp.exec_cmd("swayosd-client --playerctl play-pause"))
hl.bind("XF86AudioPause", hl.dsp.exec_cmd("swayosd-client --playerctl play-pause"))
hl.bind("XF86AudioStop", hl.dsp.exec_cmd("swayosd-client --playerctl stop"))
hl.bind("XF86AudioNext", hl.dsp.exec_cmd("swayosd-client --playerctl next"))
hl.bind("XF86AudioPrev", hl.dsp.exec_cmd("swayosd-client --playerctl prev"))
-- Мультимедиа клавиши — управление плеером + OSD

hl.bind("XF86AudioMute", hl.dsp.exec_cmd("swayosd-client --output-volume mute-toggle"))
hl.bind("XF86AudioLowerVolume", hl.dsp.exec_cmd("swayosd-client --output-volume lower"))
hl.bind("XF86AudioRaiseVolume", hl.dsp.exec_cmd("swayosd-client --output-volume raise"))
hl.bind("XF86AudioMicMute", hl.dsp.exec_cmd("swayosd-client --input-volume mute-toggle"))
-- Мультимедиа клавиши — звук и микрофон + OSD

hl.bind("XF86MonBrightnessDown", hl.dsp.exec_cmd("swayosd-client --brightness -2"))
hl.bind("XF86MonBrightnessUp", hl.dsp.exec_cmd("swayosd-client --brightness +2"))
-- Клавиши яркости — уменьшить/увеличить яркость + OSD

-- --- Resize submap ---

hl.bind(mainMod .. " + R", hl.dsp.submap("resize"))
-- Super + R — войти в режим изменения размера

hl.define_submap("resize", function()
    hl.bind("right", hl.dsp.window.resize({ x = 40,  y = 0,   relative = true }), { repeating = true })
    hl.bind("left",  hl.dsp.window.resize({ x = -40, y = 0,   relative = true }), { repeating = true })
    hl.bind("up",    hl.dsp.window.resize({ x = 0,   y = -40, relative = true }), { repeating = true })
    hl.bind("down",  hl.dsp.window.resize({ x = 0,   y = 40,  relative = true }), { repeating = true })
    hl.bind("escape", hl.dsp.submap("reset"))
    hl.bind("Return", hl.dsp.submap("reset"))
end)
-- В режиме resize:
-- стрелки — менять размер окна
-- Escape или Enter — выйти из режима
