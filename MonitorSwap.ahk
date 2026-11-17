#Requires AutoHotkey v2.0
#SingleInstance Force

; ============================================================
; MonitorSwap.ahk
; 指定した2枚のモニターの「ウィンドウ一式」を丸ごと入れ替える
;
; モニター番号は画面の「左から右」の順 (1, 2, 3)
;
;   Win+Shift+F1 : モニター1 <-> 2
;   Win+Shift+F2 : モニター1 <-> 3
;   Win+Shift+F3 : モニター2 <-> 3
;
; 写像ルール:
;   - 位置は軸ごとに比率で写す (16:9 <-> 16:10 や 縦モニターにも対応)
;   - サイズは元のまま。行き先に収まらない分だけ詰める
;   - 最大化ウィンドウは行き先で最大化し直す
;   - 最小化ウィンドウは「復元したときの位置」だけ入れ替える (最小化は維持)
;   - 指定外のモニターには一切触らない
; ============================================================

; Per-Monitor DPI Aware V2: スケーリング混在でも座標を正しく扱うための宣言
DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")

; ---- ホットキー (変えたければここを編集) ----
#+F1::SwapMonitors(1, 2)
#+F2::SwapMonitors(1, 3)
#+F3::SwapMonitors(2, 3)

; 対象外にするウィンドウクラス (シェル系)
global EXCLUDE_CLASSES := Map(
    "Progman", true,
    "WorkerW", true,
    "Shell_TrayWnd", true,
    "Shell_SecondaryTrayWnd", true
)

global SWAP_BUSY := false

A_IconTip := "MonitorSwap`nWin+Shift+F1: 1<->2 / F2: 1<->3 / F3: 2<->3"
TrayTip("Win+Shift+F1: 1<->2 / F2: 1<->3 / F3: 2<->3", "MonitorSwap 起動", 1)

; ------------------------------------------------------------
; モニター情報を左→右の順に並べて返す
; 各要素: {SysIndex, WL, WT, WR, WB}  (作業領域 = タスクバーを除いた範囲)
; ------------------------------------------------------------
GetMonitorsSorted() {
    mons := []
    count := MonitorGetCount()
    Loop count {
        i := A_Index
        MonitorGetWorkArea(i, &wl, &wt, &wr, &wb)
        mons.Push({SysIndex: i, WL: wl, WT: wt, WR: wr, WB: wb})
    }
    ; 左端の昇順にソート (台数は少ないのでバブルソートで十分)
    n := mons.Length
    Loop n - 1 {
        i := A_Index
        inner := n - i
        Loop inner {
            j := A_Index
            if (mons[j].WL > mons[j + 1].WL) {
                tmp := mons[j]
                mons[j] := mons[j + 1]
                mons[j + 1] := tmp
            }
        }
    }
    return mons
}

; 点 (cx, cy) が含まれるモニターの番号 (並び替え後) を返す。なければ 0
FindMonitor(mons, cx, cy) {
    for idx, m in mons {
        if (cx >= m.WL && cx < m.WR && cy >= m.WT && cy < m.WB)
            return idx
    }
    return 0
}

; ウィンドウの「通常表示時の矩形」を WINDOWPLACEMENT から取る
GetNormalRect(hwnd) {
    buf := Buffer(44, 0)
    NumPut("uint", 44, buf, 0)
    if (!DllCall("GetWindowPlacement", "ptr", hwnd, "ptr", buf))
        return ""
    return {L: NumGet(buf, 28, "int"), T: NumGet(buf, 32, "int"),
            R: NumGet(buf, 36, "int"), B: NumGet(buf, 40, "int")}
}

; ウィンドウの「通常表示時の矩形」だけを書き換える (表示状態は維持)
SetNormalRect(hwnd, L, T, R, B) {
    buf := Buffer(44, 0)
    NumPut("uint", 44, buf, 0)
    if (!DllCall("GetWindowPlacement", "ptr", hwnd, "ptr", buf))
        return
    NumPut("int", L, buf, 28)
    NumPut("int", T, buf, 32)
    NumPut("int", R, buf, 36)
    NumPut("int", B, buf, 40)
    DllCall("SetWindowPlacement", "ptr", hwnd, "ptr", buf)
}

; 指定モニター上にある対象ウィンドウを集める
CollectWindows(mons, monIdx) {
    result := []
    for hwnd in WinGetList() {
        try {
            if (!DllCall("IsWindowVisible", "ptr", hwnd))
                continue
            cls := WinGetClass(hwnd)
            if (EXCLUDE_CLASSES.Has(cls))
                continue
            ; Cloaked (UWP のバックグラウンド窓など) を除外
            cloaked := 0
            DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "int", 14, "int*", &cloaked, "int", 4)
            if (cloaked)
                continue
            state := WinGetMinMax(hwnd)  ; -1 最小化 / 0 通常 / 1 最大化
            if (state = 0) {
                WinGetPos(&x, &y, &w, &h, hwnd)
            } else {
                ; 最小化・最大化中は現在座標ではなく「通常表示時の矩形」を基準にする
                rect := GetNormalRect(hwnd)
                if (!rect)
                    continue
                x := rect.L
                y := rect.T
                w := rect.R - rect.L
                h := rect.B - rect.T
            }
            if (w <= 0 || h <= 0)
                continue
            cx := x + w // 2
            cy := y + h // 2
            if (FindMonitor(mons, cx, cy) != monIdx)
                continue
            result.Push({Hwnd: hwnd, State: state, X: x, Y: y, W: w, H: h})
        } catch {
            continue  ; 列挙中に閉じられたウィンドウなどは読み飛ばす
        }
    }
    return result
}

; 矩形を src モニターから dst モニターへ写像する
MapRect(x, y, w, h, src, dst) {
    srcW := src.WR - src.WL
    srcH := src.WB - src.WT
    dstW := dst.WR - dst.WL
    dstH := dst.WB - dst.WT
    nx := dst.WL + Round((x - src.WL) / srcW * dstW)
    ny := dst.WT + Round((y - src.WT) / srcH * dstH)
    nw := Min(w, dstW)
    nh := Min(h, dstH)
    ; ウィンドウ全体が行き先の作業領域に収まるよう位置をクランプ
    nx := Max(dst.WL, Min(nx, dst.WR - nw))
    ny := Max(dst.WT, Min(ny, dst.WB - nh))
    return {X: nx, Y: ny, W: nw, H: nh}
}

MoveWindow(win, src, dst) {
    r := MapRect(win.X, win.Y, win.W, win.H, src, dst)
    try {
        if (win.State = -1) {
            ; 最小化中: 復元位置だけ書き換える
            SetNormalRect(win.Hwnd, r.X, r.Y, r.X + r.W, r.Y + r.H)
        } else if (win.State = 1) {
            WinRestore(win.Hwnd)
            WinMove(r.X, r.Y, r.W, r.H, win.Hwnd)
            WinMaximize(win.Hwnd)
        } else {
            WinMove(r.X, r.Y, r.W, r.H, win.Hwnd)
        }
    } catch {
        ; 権限不足 (管理者権限のアプリ) など、動かせない窓は黙って飛ばす
    }
}

SwapMonitors(a, b) {
    global SWAP_BUSY
    if (SWAP_BUSY)
        return
    SWAP_BUSY := true
    try {
        mons := GetMonitorsSorted()
        if (a > mons.Length || b > mons.Length)
            return
        srcA := mons[a]
        srcB := mons[b]
        ; 先に両方のリストを確定させてから動かす (動かしながら集めると二重に拾う)
        winsA := CollectWindows(mons, a)
        winsB := CollectWindows(mons, b)
        active := WinExist("A")
        for win in winsA
            MoveWindow(win, srcA, srcB)
        for win in winsB
            MoveWindow(win, srcB, srcA)
        ; アクティブだったウィンドウが移動対象ならフォーカスを追従させる
        if (active) {
            for win in winsA
                if (win.Hwnd = active)
                    try WinActivate(active)
            for win in winsB
                if (win.Hwnd = active)
                    try WinActivate(active)
        }
    } finally {
        SWAP_BUSY := false
    }
}
