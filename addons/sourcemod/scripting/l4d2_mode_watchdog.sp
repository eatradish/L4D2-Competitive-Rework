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
//
// 2026-09-16 补三个与"当前跑哪个模式"无关的保镖
//（修复：房内 !match 了 1v1 zonemod 之后，服务器休眠/空置时没有回到 pure）：
//   1) sm_watchdog_no_hibernate（默认 1）——无条件把 sv_hibernate_when_empty 压在 0。
//      休眠会冻结 SourceMod timer：confogl 的 60s 空服自动卸载、本插件的所有检查都会
//      停摆。而钉值只在 sm_watchdog_mode（默认 pure）运行期间生效，跑 zm1v1 这类模式时
//      早已释放——空服一旦休眠，服务器就卡死在那个模式里出不来。所以这条不跟模式走。
//   2) sm_watchdog_foreign_timeout（默认 120s）——空服时如果跑的仍是别的模式（confogl
//      的 60s 卸载没发生：被休眠冻住；或空服时从控制台加载、没人离开就不会有 60s 计时器），
//      超过该秒数就 sm_forcechangematch 切回我们的模式；只在没有真人时生效。
//   3) sm_watchdog_heal（默认 1）——confoglcompmod 长时间消失时自愈：30 秒先 load_unlock +
//      重载 left4dhooks/confoglcompmod（模式加载中断后锁会一直挂着，带锁的 load 全部静默
//      空转）；90 秒还没回来再补 sm plugins refresh 把整个 plugins/ 扫一遍装回来。
//   4) 状态追踪：left4dhooks / confogl 每次"由有变无 / 由无变有"都会写一行带地图名的日志
//      （addons/sourcemod/logs），用时间戳抓"是谁在什么时候把 left4dhooks 弄没的"。
//   5) "confogl 在不在"用 LibraryExists("confogl") 判定（只有正在运行的 confoglcompmod
//      注册该库）。不能用 native 状态：confogl 被连锁 Error 时会谎报 Available，随后调用
//      LGO_* 直接抛异常（errors 日志里的 Blaming: l4d2_mode_watchdog.smx），异常把整次
//      检查打断、自愈分支永远跑不到。
//      （match_vote 的 "Confogl is not available"、连 sm_forcematch 都变 Unknown command
//       时，没有这条就只能人工进服重载。）
// =======================================================================================

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <confogl>      // LGO_IsMatchModeLoaded / LGO_OnMatchModeUnloaded

#define PLUGIN_VERSION "1.3.1"
#define WATCHDOG_TAG   "[ModeWatchdog]"
#define NATIVE_MATCH_LOADED "LGO_IsMatchModeLoaded"
#define FORCE_COOLDOWN 60      // 秒：两次自动强制加载之间的最小间隔
#define HEAL_FIRST_DELAY 30    // 秒：confogl 消失多久后先解锁并重载 left4dhooks/confoglcompmod
#define HEAL_FORCE_DELAY 90    // 秒：还没回来再补 refresh 把 plugins/ 整个扫一圈装回来
#define HEAL_COOLDOWN 60       // 秒：两次自愈动作之间的最小间隔

ConVar g_cvEnable;
ConVar g_cvMode;
ConVar g_cvDelay;
ConVar g_cvOnlyEmpty;
ConVar g_cvRetry;
ConVar g_cvDebug;
ConVar g_cvNoHibernate;        // 无条件保持"空服不休眠"（与模式无关）
ConVar g_cvForeignTimeout;     // 空服时跑着别的模式的兜底切回秒数
ConVar g_cvHeal;               // confoglcompmod 长时间消失时的自愈开关

Handle g_hPending = null;
bool   g_bActing  = false;
int    g_iLastForceTime = 0;   // 上次自动强制加载的时间（GetTime，秒）
int    g_iLastHumanTime = 0;   // 最近一次见到真人的时间；0 = 本次加载后还没见过（GetTime，秒）
int    g_iConfoglMissingSince = 0;  // confogl 原生不可用的起始时间；0 = 正常
int    g_iLastHealTime = 0;    // 上次自愈动作时间（GetTime，秒）

// ---- 状态追踪：抓 left4dhooks / confogl "由有变无"的瞬间（写进 SM 日志，带地图名）----
bool g_bLibStateInit = false;  // 首次取值只记录、不比较
bool g_bL4DHLast     = false;  // 上次检查时 left4dhooks 库是否在
bool g_bConfoglLast  = false;  // 上次检查时 confogl 原生是否可用

// ---- 空服不休眠（sv_hibernate_when_empty 无条件压 0，见 EnforceNoHibernate）----
ConVar g_hHibernate = null;
bool   g_bHibernateHooked = false;

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

    // 与"当前跑哪个模式"无关的三条保镖（见文件头注释）
    g_cvNoHibernate    = CreateConVar("sm_watchdog_no_hibernate", "1", "1 = 任何模式下都强制 sv_hibernate_when_empty 0（休眠会冻结 SourceMod timer，空服自动化全部停摆）", _, true, 0.0, true, 1.0);
    g_cvForeignTimeout = CreateConVar("sm_watchdog_foreign_timeout", "120.0", "空服且跑的不是 sm_watchdog_mode 时，空置超过该秒数仍未回到我们的模式就强制切回（仅无真人时生效；0 = 关闭）", _, true, 0.0, true, 3600.0);
    g_cvHeal           = CreateConVar("sm_watchdog_heal", "1", "1 = confoglcompmod 长时间消失时尝试自愈（30 秒：load_unlock + 重载 left4dhooks/confoglcompmod；90 秒：refresh 全量重扫）；故意锁加载的玩法（War Mode 等）设 0", _, true, 0.0, true, 1.0);

    HookConVarChange(g_cvNoHibernate, OnNoHibernateCvarChanged);

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
    EnforceNoHibernate();
    ScheduleCheck(g_cvDelay.FloatValue, "plugin start");
}

// 所有插件加载完成：拆卸 -> sm plugins refresh 之后必然再触发一次 ——
// 这是"空服 60s 自动卸载"那条路径上真正生效的触发点（详见 LGO_OnMatchModeUnloaded 的注释）。
public void OnAllPluginsLoaded()
{
    MaybeApplyPins();
    EnforceNoHibernate();
    ScheduleCheck(g_cvDelay.FloatValue, "all plugins loaded");
}

// 每张图兜底（AstMod confogl_autoloader 用的就是这个挂点）
public void OnMapStart()
{
    MaybeApplyPins();
    EnforceNoHibernate();
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
    // "空服起点"从模式加载这一刻重算：防止刚加载的模式（尤其空服从控制台加载的）
    // 被记成"已经空置了很久"，让 foreign 兜底立刻开火
    g_iLastHumanTime = GetTime();

    CreateTimer(2.0, Timer_ApplyPins, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_ApplyPins(Handle hTimer)
{
    MaybeApplyPins();
    EnforceNoHibernate();
    TrackLibraryStates();

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

    g_iLastHumanTime = GetTime();   // foreign 兜底的"空服起点"

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
    ReplyToCommand(client, "%s confogl=%s left4dhooks=%s matchmode_loaded=%s humans=%d pending=%s",
        WATCHDOG_TAG,
        ConfoglReady() ? "yes" : "no",
        LibraryExists("left4dhooks") ? "yes" : "no",
        (ConfoglReady() && LGO_IsMatchModeLoaded()) ? "yes" : "no",
        CountHumans(),
        (g_hPending != null) ? "yes" : "no");

    ReplyToCommand(client, "%s pin_enable=%d pinned=%d pins_applied=%s",
        WATCHDOG_TAG,
        g_cvPinEnable.BoolValue,
        (g_smPinned != null) ? g_smPinned.Size : 0,
        g_bPinsApplied ? "yes" : "no");

    char szHibernate[16] = "?";
    if (g_hHibernate != null)
    {
        g_hHibernate.GetString(szHibernate, sizeof(szHibernate));
    }

    ReplyToCommand(client, "%s no_hibernate=%d (sv_hibernate_when_empty=%s) foreign_timeout=%.1fs heal=%d",
        WATCHDOG_TAG, g_cvNoHibernate.BoolValue, szHibernate, g_cvForeignTimeout.FloatValue, g_cvHeal.BoolValue);

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

    TrackLibraryStates();

    char szMode[64];
    g_cvMode.GetString(szMode, sizeof(szMode));
    TrimString(szMode);

    if (szMode[0] == '\0')
    {
        DebugLog("sm_watchdog_mode is empty, idle");
        return;
    }

    // confogl 原生在不在（决定要不要走自愈）
    if (ConfoglReady())
    {
        g_iConfoglMissingSince = 0;
    }
    else if (g_iConfoglMissingSince == 0)
    {
        g_iConfoglMissingSince = GetTime();
    }

    if (ConfoglReady() && LGO_IsMatchModeLoaded())
    {
        // 保险：模式自己还活着但 left4dhooks 没了（正常情况 confogl 会连带倒下、走上面的自愈；
        // 这条只兜万一）。只做无锁重载，60 秒最多试一次，避免刷日志。
        if (!LibraryExists("left4dhooks"))
        {
            int iNowL4DH = GetTime();
            if (g_iLastHealTime == 0 || (iNowL4DH - g_iLastHealTime) >= HEAL_COOLDOWN)
            {
                g_iLastHealTime = iNowL4DH;
                LogMessage("%s mode is loaded but left4dhooks is missing, trying to load it back", WATCHDOG_TAG);
                ServerCommand("sm plugins load left4dhooks.smx");
            }

            ScheduleCheck(10.0, "left4dhooks missing while mode loaded");
            return;
        }

        char szCurrent[64];
        LGO_GetConfigName(szCurrent, sizeof(szCurrent));

        if (StrEqual(szCurrent, szMode, false))
        {
            DebugLog("match mode already loaded, nothing to do");
            return;
        }

        // 跑的是别的模式（例如房内 !match 开的 zm1v1）：交给空服兜底（见 CheckForeignMode）
        CheckForeignMode(szMode, szCurrent);
        return;
    }

    if (!ConfoglReady())
    {
        TryHealConfogl();
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
        g_iLastHumanTime = GetTime();
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
        int iLeft = FORCE_COOLDOWN - (iNow - g_iLastForceTime);
        DebugLog("force cooldown active (%ds left)", iLeft);

        // 冷却里也要续上重试，否则加载失败后会一直干等到下一个触发点
        ScheduleCheck(float(iLeft) + 1.0, "force cooldown");

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
// 空服兜底：别的模式占着不放
// =======================================================================================

// 空服时跑着"别的模式"（例如房内 !match 投票开的 zm1v1）：
//   * 正常情况下 confogl 自己的 60s 空服计时器会把它卸载，然后 RunCheck 的"无模式"分支
//     把我们的模式拉回来（注意那个计时器要有人断线才会开始走 —— 空服从控制台加载的模式没有）。
//   * 但休眠会冻结 SourceMod timer，两条路都会停摆；这里按"空置时长"兜底：空置超过
//     sm_watchdog_foreign_timeout 秒还没回到我们的模式，就强制 sm_forcechangematch 切回。
// 只在没有真人时生效 —— 切模式会重开图，绝不打断在局玩家。
void CheckForeignMode(const char[] szMode, const char[] szCurrent)
{
    float fTimeout = g_cvForeignTimeout.FloatValue;
    if (fTimeout <= 0.0)
    {
        DebugLog("foreign mode \"%s\" loaded, sm_watchdog_foreign_timeout is off", szCurrent);
        return;
    }

    int iHumans = CountHumans();
    if (iHumans > 0)
    {
        g_iLastHumanTime = GetTime();
        DebugLog("foreign mode \"%s\" with %d human(s), leave it alone", szCurrent, iHumans);
        return;
    }

    int iNow = GetTime();

    if (g_iLastHumanTime == 0)
    {
        // 本次加载后还没见过真人：已经空置多久无从考证，从现在开始计时
        g_iLastHumanTime = iNow;
        DebugLog("foreign mode \"%s\": no humans seen since load, start empty timer (%.0fs)", szCurrent, fTimeout);
        ScheduleCheck(fTimeout, "foreign mode empty timer");
        return;
    }

    float fEmpty = float(iNow - g_iLastHumanTime);

    if (fEmpty < fTimeout)
    {
        DebugLog("foreign mode \"%s\": empty for %.0fs of %.0fs", szCurrent, fEmpty, fTimeout);
        ScheduleCheck((fTimeout - fEmpty < 60.0) ? (fTimeout - fEmpty) : 60.0, "foreign mode waiting");
        return;
    }

    if (g_iLastForceTime > 0 && (iNow - g_iLastForceTime) < FORCE_COOLDOWN)
    {
        int iLeft = FORCE_COOLDOWN - (iNow - g_iLastForceTime);
        DebugLog("force cooldown active (%ds left)", iLeft);
        ScheduleCheck(float(iLeft) + 1.0, "foreign mode cooldown");
        return;
    }

    g_bActing = true;
    g_iLastForceTime = iNow;

    LogMessage("%s \"%s\" is still loaded %.0fs after the server went empty, switching to \"%s\"",
        WATCHDOG_TAG, szCurrent, fEmpty, szMode);

    ServerCommand("sm_forcechangematch %s", szMode);

    ScheduleCheck(15.0, "verify after foreign mode switch");

    g_bActing = false;
}

// =======================================================================================
// confogl 消失自愈
// =======================================================================================

// confoglcompmod.smx 长时间不可用时把根目录插件刷回来。正常情况下它只会在"模式加载的空窗"
// 里短暂消失（几秒内就被 cfg 链装回来），所以先等 30 秒再动手；一个"完整加载"正在进行时
// （confogl_match_reloaded != 0）不掺和，除非它卡了 90 秒以上（那说明这次加载已经断了）。
//   第一级（30s）：load_unlock + 重载 left4dhooks / confoglcompmod。必须先解锁：模式加载
//                 中断后 sm plugins load_lock 会一直挂着，带锁的 load 全部静默空转（只打
//                 控制台、不进日志）——这正是"点了没反应、手动却行"的坑。
//   第二级（90s）：再补一次 load_unlock + sm plugins refresh——重新扫描整个 plugins/，
//                 把还缺席的插件（含各种依赖 left4dhooks 而 <Error> 的）一次性装回来。
void TryHealConfogl()
{
    if (!g_cvHeal.BoolValue || g_iConfoglMissingSince == 0)
    {
        return;
    }

    int iNow = GetTime();
    int iMissing = iNow - g_iConfoglMissingSince;

    if (iMissing < HEAL_FIRST_DELAY)
    {
        return;
    }

    if (g_iLastHealTime > 0 && (iNow - g_iLastHealTime) < HEAL_COOLDOWN)
    {
        return;
    }

    ConVar hReloaded = FindConVar("confogl_match_reloaded");
    bool bLoadStuck = (hReloaded != null && hReloaded.IntValue != 0);

    if (iMissing < HEAL_FORCE_DELAY)
    {
        if (bLoadStuck)
        {
            DebugLog("heal: a mode load seems in progress, wait");
            return;
        }

        LogMessage("%s confogl has been gone for %ds (left4dhooks=%s), unlocking and reloading left4dhooks + confoglcompmod",
            WATCHDOG_TAG, iMissing, LibraryExists("left4dhooks") ? "yes" : "no");
        ServerCommand("sm plugins load_unlock");
        ServerCommand("sm plugins load left4dhooks.smx");
        ServerCommand("sm plugins load confoglcompmod.smx");
    }
    else
    {
        if (bLoadStuck)
        {
            DebugLog("heal: clearing stuck confogl_match_reloaded (%d)", hReloaded.IntValue);
            hReloaded.SetInt(0);
        }

        LogMessage("%s confogl still gone after %ds (left4dhooks=%s), forcing load_unlock + plugins refresh",
            WATCHDOG_TAG, iMissing, LibraryExists("left4dhooks") ? "yes" : "no");
        ServerCommand("sm plugins load_unlock");
        ServerCommand("sm plugins refresh");
    }

    g_iLastHealTime = iNow;
}

// =======================================================================================
// 空服不休眠（与模式无关）
// =======================================================================================

// sv_hibernate_when_empty 必须是 0，无论当前跑哪个模式：
//   * 休眠会冻结 SourceMod timer —— confogl 的 60s 空服自动卸载、本插件的所有检查全部停摆；
//   * 跑非 pure 模式时钉值已经释放，如果这时允许休眠，空服就会卡死在那个模式里（本插件也
//     救不回来，因为 timer 不走：重连的人还在的时候 confogl 又不会卸载）。
// 与钉值的区别：不记录/还原原值、不随模式卸载释放 —— 就是一直压在 0。管理员显式关掉
// sm_watchdog_no_hibernate、或把它加进钉值清单交给钉值机制接管时除外。
void EnforceNoHibernate()
{
    if (!g_cvNoHibernate.BoolValue)
    {
        return;
    }

    if (g_hHibernate == null)
    {
        g_hHibernate = FindConVar("sv_hibernate_when_empty");
        if (g_hHibernate == null)
        {
            DebugLog("no-hibernate: sv_hibernate_when_empty not found");
            return;
        }
    }

    // 管理员用 sm_watchdog_pin 单独钉过它的话，让钉值机制说了算
    if (g_smPinned != null && g_smPinned.ContainsKey("sv_hibernate_when_empty"))
    {
        return;
    }

    if (!g_bHibernateHooked)
    {
        HookConVarChange(g_hHibernate, OnHibernateChanged);
        g_bHibernateHooked = true;
    }

    if (g_hHibernate.IntValue != 0)
    {
        DebugLog("no-hibernate: sv_hibernate_when_empty %d -> 0", g_hHibernate.IntValue);

        g_bPinIgnore = true;
        SetConVarStringSilence(g_hHibernate, "0");
        g_bPinIgnore = false;
    }
}

// 谁把它改成非 0 都顶回 0（引擎每图/其它插件/控制台）
public void OnHibernateChanged(ConVar convar, const char[] szOldValue, const char[] szNewValue)
{
    if (g_bPinIgnore || !g_cvNoHibernate.BoolValue)
    {
        return;
    }

    if (StrEqual(szNewValue, "0"))
    {
        return;
    }

    if (g_smPinned != null && g_smPinned.ContainsKey("sv_hibernate_when_empty"))
    {
        return;
    }

    DebugLog("no-hibernate: reverted sv_hibernate_when_empty from \"%s\" to \"0\"", szNewValue);

    g_bPinIgnore = true;
    SetConVarStringSilence(convar, "0");
    g_bPinIgnore = false;
}

// sm_watchdog_no_hibernate 被打开时立刻补一次
public void OnNoHibernateCvarChanged(ConVar convar, const char[] szOldValue, const char[] szNewValue)
{
    if (convar.BoolValue)
    {
        EnforceNoHibernate();
    }
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

// =======================================================================================
// 状态追踪（抓 left4dhooks / confogl "由有变无"的瞬间）
// =======================================================================================

// 每次检查都把 left4dhooks 库与 confogl 原生是否可用记下来；由"在"变"不在"（或反过来）时
// 写一行带地图/状态/人数的日志 —— 用于定位"是谁在什么时候把它们弄没的"。
// 消失的那一下还会顺手排一次 5 秒后的检查，让自愈路径（confogl 消失分支）尽快接管。
void TrackLibraryStates()
{
    bool bL4DH    = LibraryExists("left4dhooks");
    bool bConfogl = ConfoglReady();

    if (g_bLibStateInit)
    {
        char szMap[64];
        GetCurrentMap(szMap, sizeof(szMap));

        if (g_bL4DHLast && !bL4DH)
        {
            LogMessage("%s left4dhooks disappeared! (map=%s confogl=%s mode_loaded=%s humans=%d)",
                WATCHDOG_TAG, szMap, bConfogl ? "yes" : "no",
                (bConfogl && LGO_IsMatchModeLoaded()) ? "yes" : "no", CountHumans());
            ScheduleCheck(5.0, "left4dhooks disappeared");
        }
        else if (!g_bL4DHLast && bL4DH)
        {
            LogMessage("%s left4dhooks is back (map=%s)", WATCHDOG_TAG, szMap);
        }

        if (g_bConfoglLast && !bConfogl)
        {
            LogMessage("%s confogl native disappeared! (map=%s left4dhooks=%s)",
                WATCHDOG_TAG, szMap, bL4DH ? "yes" : "no");
        }
        else if (!g_bConfoglLast && bConfogl)
        {
            LogMessage("%s confogl native is back (map=%s)", WATCHDOG_TAG, szMap);
        }
    }

    g_bL4DHLast     = bL4DH;
    g_bConfoglLast  = bConfogl;
    g_bLibStateInit = true;
}

bool ConfoglReady()
{
    // 用库检查而不是 GetFeatureStatus(native)：confoglcompmod 被"连锁 Error"（evict）后的
    // 半死状态里，native 检查会谎报 Available，守卫放行后真正调用 LGO_* 会抛异常
    // （errors 日志反复出现的 "Blaming: l4d2_mode_watchdog.smx" 就是它）——异常会把整次
    // RunCheck 打断，自愈分支永远执行不到。只有"正在运行"的 confoglcompmod 才会注册
    // "confogl" 库（confoglcompmod.sp AskPluginLoad2），Error/卸载后立即为 false。
    return LibraryExists("confogl");
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
