// =======================================================================================
// l4d2_mode_watchdog.sp - 模式看门狗
//
// 解决的问题：
//   confogl 在服务器空置 ~60s 后会自动卸载当前模式（ReqMatch.sp RESETMINTIME 60.0），
//   随后 confogl_off.cfg 拆卸 cvar / 插件，服务器回到"无模式"状态。
//   本插件负责在"该有模式却没有"的时候把模式重新拉起来，**不改动任何第三方源码**。
//
// 为什么这样可行（都在 confogl 源码里验证过）：
//   1) ReqMatch.sp:321  RM_Cmd_ForceMatch() 在模式已加载时直接 return
//      -> 反复调用 sm_forcematch 是空操作，不会触发重开图死循环。
//   2) 拆卸走 pred_unload_plugins -> sm plugins unload_all + sm plugins refresh，
//      refresh 会把 plugins/ 根目录的插件（含 confoglcompmod.smx 和本插件）重新加载，
//      confogl 新实例的 RM_bIsPluginsLoaded == false
//      -> 此后 sm_forcematch 会走"完整加载"路径（unload_all + 重新 exec
//         generalfixes.cfg;confogl_plugins.cfg;sharedplugins.cfg），模式和插件一起回来。
//      服务器控制台会打印 "Loading plugins and reload self"（完整）而不是
//      "Match config executed"（半加载）。
//   3) 触发点用 OnAllPluginsLoaded：上面那次 refresh 之后必然再触发一次，
//      比"等换图"更及时（参考 AstMod 的 confogl_autoloader 与 TouchMe 的 cm_autoload）。
//
// 与 confogl 内置 confogl_match_autoload 的区别：
//   内置那个挂在 OnClientPutInServer，会在首个玩家还没完成 sign-on 时重开图，
//   导致该玩家客户端崩溃（上游 PR #1010）。本插件只在"没有真人在局内"时动手。
// =======================================================================================

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <confogl>      // LGO_IsMatchModeLoaded / LGO_OnMatchModeUnloaded

#define PLUGIN_VERSION "1.0.0"
#define WATCHDOG_TAG   "[ModeWatchdog]"
#define NATIVE_MATCH_LOADED "LGO_IsMatchModeLoaded"
#define FORCE_COOLDOWN 60      // 秒：两次自动强制加载之间的最小间隔

ConVar g_cvEnable;
ConVar g_cvMode;
ConVar g_cvDelay;
ConVar g_cvOnlyEmpty;
ConVar g_cvRetry;
ConVar g_cvDebug;

Handle g_hPending = null;
bool   g_bActing  = false;
int    g_iLastForceTime = 0;   // 上次自动强制加载的时间（GetTime，秒）

// ---- cvar 钉值（思路来自 TouchMe-Inc/l4d2_config_manager 的 config_manager_addcvar）----
// 模式在跑期间，把清单里的 cvar 钉住：谁改动都被立刻顶回去（引擎每图 Revert、别的插件、
// 甚至 confogl 自己卸载时的 write-back），模式卸载时释放并还原成钉住前的值。
ConVar    g_cvPinEnable;
ConVar    g_cvPinsFile;
StringMap g_smPinned    = null;   // cvar 名 -> 钉住前的原值（释放时用它还原）
bool      g_bPinIgnore  = false;  // 防止我们自己设值触发 hook 回调
bool      g_bPinsApplied = false;

public Plugin myinfo =
{
    name        = "Confogl Mode Watchdog",
    author      = "L4D2-Comp-Source",
    description = "Re-loads the configured confogl match mode when it is missing (survives the empty-server auto-unload).",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/eatradish/L4D2-Competitive-Rework"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if (GetEngineVersion() != Engine_Left4Dead2)
    {
        strcopy(error, err_max, "Plugin only supports Left 4 Dead 2.");
        return APLRes_SilentFailure;
    }

    return APLRes_Success;
}

public void OnPluginStart()
{
    g_cvEnable    = CreateConVar("sm_watchdog_enable", "1", "0 = 关闭看门狗", _, true, 0.0, true, 1.0);
    g_cvMode      = CreateConVar("sm_watchdog_mode", "pure", "要保证在跑的模式名（cfg/cfgogl/ 下的目录名）；留空 = 关闭");
    g_cvDelay     = CreateConVar("sm_watchdog_delay", "10.0", "触发后等待多少秒再检查（等插件加载/refresh 收尾）", _, true, 0.0, true, 300.0);
    g_cvOnlyEmpty = CreateConVar("sm_watchdog_only_empty", "1", "1 = 只有没有真人在局内时才动手（避免打断手动切模式 / 避免重开图伤害在局玩家）", _, true, 0.0, true, 1.0);
    g_cvRetry     = CreateConVar("sm_watchdog_retry", "30.0", "因为有人在局内而被跳过时，多少秒后重试；0 = 不重试（等下一个触发点）", _, true, 0.0, true, 600.0);
    g_cvDebug     = CreateConVar("sm_watchdog_debug", "0", "1 = 输出详细日志", _, true, 0.0, true, 1.0);

    g_cvPinEnable = CreateConVar("sm_watchdog_pin_enable", "1", "1 = 模式在跑期间钉住 sm_watchdog_pins_file 里列出的 cvar（别人改动会被立刻顶回去）", _, true, 0.0, true, 1.0);
    g_cvPinsFile  = CreateConVar("sm_watchdog_pins_file", "watchdog_pins.cfg", "钉值清单（相对 cfg/ 的路径）");

    g_smPinned = new StringMap();

    AutoExecConfig(true, "l4d2_mode_watchdog");

    RegAdminCmd("sm_watchdog", Cmd_Watchdog, ADMFLAG_CONFIG, "sm_watchdog [status|now] - 查看状态 / 立即检查一次（忽略 only_empty）");

    RegServerCmd("sm_watchdog_pin", Cmd_Pin, "sm_watchdog_pin <cvar> <value> - 设置并钉住一个 cvar（供 cfg 使用）");
    RegServerCmd("sm_watchdog_unpin", Cmd_Unpin, "sm_watchdog_unpin <cvar> - 解除钉住并还原原值");
    RegServerCmd("sm_watchdog_unpin_all", Cmd_UnpinAll, "sm_watchdog_unpin_all - 解除全部钉住并还原原值");

    // 插件加载时来一次（开机、以及拆卸后 refresh 重新加载本插件时）
    MaybeApplyPins();
    ScheduleCheck(g_cvDelay.FloatValue, "plugin start");
}

// 所有插件加载完成：拆卸 -> sm plugins refresh 之后必然再触发一次 ——
// 这是"空服 60s 自动卸载"那条路径上真正生效的触发点（详见 LGO_OnMatchModeUnloaded 的注释）。
public void OnAllPluginsLoaded()
{
    MaybeApplyPins();
    ScheduleCheck(g_cvDelay.FloatValue, "all plugins loaded");
}

// 每张图兜底（AstMod confogl_autoloader 用的就是这个挂点）
public void OnMapStart()
{
    MaybeApplyPins();
    ScheduleCheck(g_cvDelay.FloatValue, "map start");
}

// 模式被 confogl 卸载 —— 这就是"最后一个真人退出后 60 秒"那个事件：
//   ReqMatch.sp RM_OnClientDisconnect -> CreateTimer(60.0) -> RM_MatchResetTimer -> RM_Match_Unload()
//   RM_Match_Unload() 里先置 RM_bIsMatchModeLoaded = false，然后才 Call_StartForward(RM_hFwdMatchUnload)
//   （所以回调里 LGO_IsMatchModeLoaded() 已经是 false），最后才 exec confogl_off.cfg。
// 注意：confogl_off.cfg 里的 pred_unload_plugins 会把本插件也一起卸载，所以这里排的 3s 定时器
// 在这条路径上活不到触发 —— 真正接住这次拆卸的是下面第二条保险：
// pred_unload_plugins -> sm plugins refresh（0.1s 后）重新加载 plugins/ 根目录插件 ->
// 本插件重新加载 -> OnPluginStart / OnAllPluginsLoaded -> 延迟检查 -> sm_forcematch pure。
// 而 RM_Match_Unload() 同时把 RM_bIsPluginsLoaded 置回 false，所以那次加载走的是"完整路径"
// （unload_all + 重新 exec 三个 plugins cfg），插件与 cvar 一起回来。
// 另外 RM_Match_Unload() 开头有 `if (bIsHumansOnServer && !bForced) return;`：如果这 60 秒里
// 有人进来了，confogl 根本不会卸载，本插件也不会动手。
public void LGO_OnMatchModeUnloaded()
{
    ReleasePins();
    ScheduleCheck(3.0, "match mode unloaded (60s empty timer / sm_resetmatch)");
}

// 模式加载完成后把钉值压上（延迟 2s，等模式自己的 cfg 执行完）
public void LGO_OnMatchModeLoaded()
{
    CreateTimer(2.0, Timer_ApplyPins, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_ApplyPins(Handle hTimer)
{
    MaybeApplyPins();

    return Plugin_Stop;
}

// 插件被卸载（模式加载开头的 sm plugins unload_all、pred_unload_plugins、手动 unload）时
// 把钉值释放掉并还原原值，避免"钩子随插件消失、值却留在钉住状态"。
public void OnPluginEnd()
{
    ReleasePins();
}

// 有人离开时补一次检查（是不是最后一个人，交给延迟后的检查自己判断 —— 回调触发时
// 该客户端在引擎里还算是"连着"的，所以这里不能立刻数人数）
public void OnClientDisconnect(int client)
{
    if (client <= 0 || client > MaxClients || IsFakeClient(client))
    {
        return;
    }

    ScheduleCheck(5.0, "client disconnected");
}

Action Cmd_Watchdog(int client, int args)
{
    char szArg[16];
    if (args >= 1)
    {
        GetCmdArg(1, szArg, sizeof(szArg));
    }

    if (StrEqual(szArg, "now", false))
    {
        ReplyToCommand(client, "%s forcing a check now (ignoring only_empty)...", WATCHDOG_TAG);
        RunCheck(true);
        return Plugin_Handled;
    }

    char szMode[64];
    g_cvMode.GetString(szMode, sizeof(szMode));
    TrimString(szMode);

    ReplyToCommand(client, "%s enable=%d mode=\"%s\" only_empty=%d delay=%.1fs retry=%.1fs",
        WATCHDOG_TAG,
        g_cvEnable.BoolValue,
        szMode,
        g_cvOnlyEmpty.BoolValue,
        g_cvDelay.FloatValue,
        g_cvRetry.FloatValue);
    ReplyToCommand(client, "%s confogl=%s matchmode_loaded=%s humans=%d pending=%s",
        WATCHDOG_TAG,
        ConfoglReady() ? "yes" : "no",
        (ConfoglReady() && LGO_IsMatchModeLoaded()) ? "yes" : "no",
        CountHumans(),
        (g_hPending != null) ? "yes" : "no");

    ReplyToCommand(client, "%s pin_enable=%d pinned=%d pins_applied=%s",
        WATCHDOG_TAG,
        g_cvPinEnable.BoolValue,
        (g_smPinned != null) ? g_smPinned.Size : 0,
        g_bPinsApplied ? "yes" : "no");

    return Plugin_Handled;
}

void ScheduleCheck(float fDelay, const char[] sReason)
{
    if (!g_cvEnable.BoolValue)
    {
        return;
    }

    if (g_hPending != null)
    {
        KillTimer(g_hPending);
        g_hPending = null;
    }

    DataPack hPack = new DataPack();
    hPack.WriteString(sReason);
    g_hPending = CreateTimer(fDelay, Timer_Check, hPack, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_Check(Handle hTimer, DataPack hPack)
{
    g_hPending = null;

    char sReason[64];
    hPack.Reset();
    hPack.ReadString(sReason, sizeof(sReason));
    delete hPack;

    DebugLog("check triggered by: %s", sReason);
    RunCheck(false);

    return Plugin_Stop;
}

void RunCheck(bool bIgnoreEmpty)
{
    if (!g_cvEnable.BoolValue)
    {
        return;
    }

    if (g_bActing)
    {
        DebugLog("already acting, skip");
        return;
    }

    char szMode[64];
    g_cvMode.GetString(szMode, sizeof(szMode));
    TrimString(szMode);

    if (szMode[0] == '\0')
    {
        DebugLog("sm_watchdog_mode is empty, idle");
        return;
    }

    // confogl 还没加载好（拆卸和 refresh 之间的窗口）-> 稍后重试
    if (ConfoglReady() && LGO_IsMatchModeLoaded())
    {
        DebugLog("match mode already loaded, nothing to do");
        return;
    }

    if (!ConfoglReady())
    {
        DebugLog("confogl native not available yet, retry in 5s");
        ScheduleCheck(5.0, "confogl not ready");
        return;
    }

    // 模式正在加载中（RM_Match_Load 的插件阶段会置 confogl_match_reloaded=1）：
    // 这时候插手会跟它自己的 unload_all + exec 打架，等它跑完再说。
    ConVar hReloaded = FindConVar("confogl_match_reloaded");
    if (hReloaded != null && hReloaded.IntValue != 0)
    {
        DebugLog("confogl_match_reloaded != 0 (a mode load is in progress), retry in 10s");
        ScheduleCheck(10.0, "mode load in progress");
        return;
    }

    int iHumans = CountHumans();

    if (g_cvOnlyEmpty.BoolValue && !bIgnoreEmpty && iHumans > 0)
    {
        float fRetry = g_cvRetry.FloatValue;
        DebugLog("%d human(s) in game, skip and retry in %.1fs", iHumans, fRetry);

        if (fRetry > 0.0)
        {
            ScheduleCheck(fRetry, "humans online");
        }

        return;
    }

    // 冷却：避免配置名写错（sm_forcematch 会直接失败）时每 15 秒刷一次日志 / 反复重试
    int iNow = GetTime();
    if (!bIgnoreEmpty && g_iLastForceTime > 0 && (iNow - g_iLastForceTime) < FORCE_COOLDOWN)
    {
        DebugLog("force cooldown active (%ds left)", FORCE_COOLDOWN - (iNow - g_iLastForceTime));
        return;
    }

    g_bActing = true;
    g_iLastForceTime = iNow;

    LogMessage("%s no match mode loaded, forcing \"%s\" (humans %d, only_empty %d)",
        WATCHDOG_TAG, szMode, iHumans, g_cvOnlyEmpty.BoolValue);

    ServerCommand("sm_forcematch %s", szMode);

    // 给 sm_forcematch 一点时间把模式加载起来，随后复查一次（加载失败时能看出来）
    ScheduleCheck(15.0, "verify after force");

    g_bActing = false;
}

// =======================================================================================
// cvar 钉值
// =======================================================================================

Action Cmd_Pin(int args)
{
    if (args != 2)
    {
        PrintToServer("%s usage: sm_watchdog_pin <cvar> <value>", WATCHDOG_TAG);
        return Plugin_Handled;
    }

    char szName[64], szValue[128];
    GetCmdArg(1, szName, sizeof(szName));
    GetCmdArg(2, szValue, sizeof(szValue));

    ConVar hConVar = FindConVar(szName);
    if (hConVar == null)
    {
        PrintToServer("%s sm_watchdog_pin: cvar not found: %s", WATCHDOG_TAG, szName);
        return Plugin_Handled;
    }

    if (g_smPinned.ContainsKey(szName))
    {
        // 已经钉过：只把值压回去，保留最初记录的原值（这样本文件可以重复 exec）
        g_bPinIgnore = true;
        SetConVarStringSilence(hConVar, szValue);
        g_bPinIgnore = false;

        return Plugin_Handled;
    }

    char szOriginal[128];
    GetConVarString(hConVar, szOriginal, sizeof(szOriginal));

    g_smPinned.SetString(szName, szOriginal);
    HookConVarChange(hConVar, OnConVarChanged);

    g_bPinIgnore = true;
    SetConVarStringSilence(hConVar, szValue);
    g_bPinIgnore = false;

    DebugLog("pin: %s = \"%s\" (was \"%s\")", szName, szValue, szOriginal);

    return Plugin_Handled;
}

Action Cmd_Unpin(int args)
{
    if (args != 1)
    {
        PrintToServer("%s usage: sm_watchdog_unpin <cvar>", WATCHDOG_TAG);
        return Plugin_Handled;
    }

    char szName[64];
    GetCmdArg(1, szName, sizeof(szName));

    UnpinOne(szName);

    return Plugin_Handled;
}

Action Cmd_UnpinAll(int args)
{
    ReleasePins();

    return Plugin_Handled;
}

void UnpinOne(const char[] szName)
{
    if (g_smPinned == null || !g_smPinned.ContainsKey(szName))
    {
        return;
    }

    char szOriginal[128];
    g_smPinned.GetString(szName, szOriginal, sizeof(szOriginal));
    g_smPinned.Remove(szName);

    ConVar hConVar = FindConVar(szName);
    if (hConVar == null)
    {
        return;
    }

    UnhookConVarChange(hConVar, OnConVarChanged);

    g_bPinIgnore = true;
    SetConVarStringSilence(hConVar, szOriginal);
    g_bPinIgnore = false;

    DebugLog("pin: %s released -> \"%s\"", szName, szOriginal);
}

void ReleasePins()
{
    g_bPinsApplied = false;

    if (g_smPinned == null || g_smPinned.Size == 0)
    {
        return;
    }

    StringMapSnapshot hSnapshot = g_smPinned.Snapshot();

    char szName[64];
    for (int i = 0; i < hSnapshot.Length; i++)
    {
        hSnapshot.GetKey(i, szName, sizeof(szName));
        UnpinOne(szName);
    }

    delete hSnapshot;

    DebugLog("pin: all released");
}

// 只有"我们负责的那个模式"正在跑的时候才钉值
bool IsOurModeLoaded()
{
    if (!ConfoglReady() || !LGO_IsMatchModeLoaded())
    {
        return false;
    }

    char szMode[64];
    g_cvMode.GetString(szMode, sizeof(szMode));
    TrimString(szMode);

    if (szMode[0] == '\0')
    {
        return false;
    }

    char szCurrent[64];
    LGO_GetConfigName(szCurrent, sizeof(szCurrent));

    return StrEqual(szCurrent, szMode, false);
}

// 执行钉值清单。语义上幂等（重复 exec 只会把值压回去），所以每图/每次插件重载都跑一次也没问题。
void MaybeApplyPins()
{
    if (!g_cvPinEnable.BoolValue || g_cvPinsFile == null)
    {
        return;
    }

    if (!IsOurModeLoaded())
    {
        return;
    }

    char szFile[PLATFORM_MAX_PATH];
    g_cvPinsFile.GetString(szFile, sizeof(szFile));
    TrimString(szFile);

    if (szFile[0] == '\0')
    {
        return;
    }

    char szPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, szPath, sizeof(szPath), "../../cfg/%s", szFile);

    if (!FileExists(szPath))
    {
        DebugLog("pin: file not found: %s", szPath);
        return;
    }

    ServerCommand("exec %s", szFile);
    g_bPinsApplied = true;

    DebugLog("pin: exec %s", szFile);
}

// 别人改动被钉住的 cvar -> 立刻顶回改动前的值（szOldValue 就是钉住时的值）
public void OnConVarChanged(ConVar convar, const char[] szOldValue, const char[] szNewValue)
{
    if (g_bPinIgnore)
    {
        return;
    }

    char szName[64];
    convar.GetName(szName, sizeof(szName));

    if (g_smPinned == null || !g_smPinned.ContainsKey(szName))
    {
        return;
    }

    if (StrEqual(szOldValue, szNewValue))
    {
        return;
    }

    g_bPinIgnore = true;
    SetConVarStringSilence(convar, szOldValue);
    g_bPinIgnore = false;

    DebugLog("pin: reverted %s from \"%s\" to \"%s\"", szName, szNewValue, szOldValue);
}

// 改值时临时去掉 FCVAR_NOTIFY，避免刷屏/触发通知
void SetConVarStringSilence(ConVar convar, const char[] sValue)
{
    int iFlags = GetConVarFlags(convar);
    SetConVarFlags(convar, iFlags & ~FCVAR_NOTIFY);
    SetConVarString(convar, sValue);
    SetConVarFlags(convar, iFlags);
}

bool ConfoglReady()
{
    return GetFeatureStatus(FeatureType_Native, NATIVE_MATCH_LOADED) == FeatureStatus_Available;
}

// 真人数量：连着的就算（含正在 sign-on 的），避免在别人进服过程中重开图
int CountHumans()
{
    int iCount = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && !IsFakeClient(i))
        {
            iCount++;
        }
    }

    return iCount;
}

void DebugLog(const char[] sFormat, any...)
{
    if (!g_cvDebug.BoolValue)
    {
        return;
    }

    char sBuffer[256];
    VFormat(sBuffer, sizeof(sBuffer), sFormat, 2);

    LogMessage("%s %s", WATCHDOG_TAG, sBuffer);
}
