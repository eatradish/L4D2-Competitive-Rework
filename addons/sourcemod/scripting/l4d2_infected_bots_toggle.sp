#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <colors>

#define PLUGIN_VERSION "1.0.0"

#define SI_CVAR "director_allow_infected_bots"

// ---------------------------------------------------------------------------
// 管理员一键开关「导演刷 AI 特感」。
//
// 受控 cvar: director_allow_infected_bots
//   1 = 导演可以刷 AI 特感补位（pure / baokang 的默认）
//   0 = 只有真人特感（zonemod 系默认）
//
// 为什么要做"接管"——这两处会把值改掉：
//   1) 引擎每次换图（Host_NewGame -> ResetGameConVarsToDefaults）会把
//      "director_*" 系列 cvar 重置回默认值；
//   2) 模式加载 / 每图执行 cfg 时，confogl_addcvar 会再写回模式值。
// 所以用 sm_si_override 记录管理员的选择，并在变更钩子 + OnConfigsExecuted
// 里把它压回去，保证跨换图、跨模式重载都保持有效。
// 接管只在本次服务器进程内有效（重启服务器后回到"跟随模式配置"）。
// ---------------------------------------------------------------------------

ConVar
	g_hCvarBots     = null,  // director_allow_infected_bots
	g_hCvarOverride = null;  // sm_si_override: -1 跟随 / 0 强制关 / 1 强制开

bool g_bApplying = false;    // 防止 SetInt 触发变更钩子后递归
int  g_iModeValue = -1;      // 最近一次由外部（模式 cfg / 换图重置）写入的值

public Plugin myinfo =
{
	name        = "[L4D2] Infected Bots Toggle",
	author      = "L4D2-Comp-Source",
	description = "Admin one-key toggle for the director's AI special infected spawning.",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_hCvarBots = FindConVar(SI_CVAR);
	if (g_hCvarBots == null)
	{
		SetFailState("Missing cvar \"%s\" (L4D2 only)", SI_CVAR);
	}
	g_hCvarBots.AddChangeHook(OnBotsCvarChanged);

	g_hCvarOverride = CreateConVar("sm_si_override", "-1",
		"Director AI special toggle override: -1 = follow mode config, 0 = forced off, 1 = forced on.",
		FCVAR_DONTRECORD, true, -1.0, true, 1.0);

	RegAdminCmd("sm_si", Cmd_ToggleSI, ADMFLAG_CONFIG,
		"Toggle the director's AI special infected: no arg = flip, 1 = on, 0 = off, reset = follow mode config");

	if (g_hCvarOverride.IntValue == -1)
	{
		g_iModeValue = g_hCvarBots.IntValue;
	}

	ApplyOverride();
}

public void OnConfigsExecuted()
{
	ApplyOverride();
}

public void OnBotsCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (g_bApplying)
	{
		return;
	}

	int iValue = convar.IntValue;
	int iOverride = g_hCvarOverride.IntValue;

	// 记下外部写入的值：没接管时它就是模式值；接管时它多半是模式 cfg / 换图重置写回来的。
	g_iModeValue = iValue;

	if (iOverride != -1 && iValue != iOverride)
	{
		SetBotsValue(iOverride);
	}
}

void ApplyOverride()
{
	int iOverride = g_hCvarOverride.IntValue;
	if (iOverride != -1 && g_hCvarBots.IntValue != iOverride)
	{
		SetBotsValue(iOverride);
	}
}

void SetBotsValue(int iValue)
{
	g_bApplying = true;
	g_hCvarBots.SetInt(iValue);
	g_bApplying = false;
}

Action Cmd_ToggleSI(int client, int args)
{
	if (args >= 1)
	{
		char sArg[16];
		GetCmdArg(1, sArg, sizeof(sArg));

		if (StrEqual(sArg, "reset", false) || StrEqual(sArg, "r", false))
		{
			ResetOverride(client);
			return Plugin_Handled;
		}

		int iValue;
		if (StrEqual(sArg, "1", false) || StrEqual(sArg, "on", false))
		{
			iValue = 1;
		}
		else if (StrEqual(sArg, "0", false) || StrEqual(sArg, "off", false))
		{
			iValue = 0;
		}
		else
		{
			ReplyToCommand(client, "[SI] 用法: !si 切换 / !si 1 开启 / !si 0 关闭 / !si reset 恢复跟随模式");
			return Plugin_Handled;
		}

		SetOverride(client, iValue);
		return Plugin_Handled;
	}

	// 无参数：按当前实际生效值取反。
	SetOverride(client, g_hCvarBots.IntValue != 0 ? 0 : 1);
	return Plugin_Handled;
}

void SetOverride(int client, int iValue)
{
	g_hCvarOverride.SetInt(iValue);
	SetBotsValue(iValue);

	AnnounceChange(client, iValue);
	LogAction(client, -1, "set %s = %d (AI special toggle)", SI_CVAR, iValue);
}

void ResetOverride(int client)
{
	g_hCvarOverride.SetInt(-1);

	int iRestore = (g_iModeValue >= 0) ? g_iModeValue : g_hCvarBots.IntValue;
	SetBotsValue(iRestore);
	g_iModeValue = iRestore;

	ReplyToCommand(client, "[SI] 已恢复为跟随模式配置（当前值: %d）", iRestore);
	LogAction(client, -1, "reset %s to mode config (%d)", SI_CVAR, iRestore);
}

void AnnounceChange(int client, int iValue)
{
	char sAdmin[64];
	if (client > 0)
	{
		FormatEx(sAdmin, sizeof(sAdmin), "管理员 %N", client);
	}
	else
	{
		strcopy(sAdmin, sizeof(sAdmin), "控制台");
	}

	if (iValue == 1)
	{
		CPrintToChatAll("{blue}[特感开关]{default} %s 已开启：导演可以刷 AI 特感补位", sAdmin);
	}
	else
	{
		CPrintToChatAll("{blue}[特感开关]{default} %s 已关闭：只有真人特感", sAdmin);
	}
}
