#pragma newdecls required

#include <sourcemod>

/******************************************************************
*
* v1.0
* ------------------------
* ------- Details: -------
* ------------------------
* - Establishes Server Commands for the following:
* --> Unloading Plugins with the argument being the folder you want to unload the plugins from, leave the argument empty if you wish to unload just the main folder.
* --> Reserving Plugins, meaning these plugins will not be unloaded when the previously mentioned Plugin Unload is unloading the folder these plugins reside in.
* --> Unloading Reserved Plugins, this function will unload the reserved plugins in the order from "Last Reserved" to "First Reserved".

* v1.1
* ------------------------
* ------- Details: -------
* ------------------------
* - Overhauled it with keyCat's feedback in mind.
* --> Unloading Plugins with the pred_unload_plugins will push all currently loaded plugins to the Array and unloads them from Last loaded to First loaded. This way, dependencies should'nt be an issue.
* --> Removed the possibility of just Unloading Reserved Plugins... as there's no need for it?
*
*
* v1.2
* ------------------------
* ------- Details: -------
* ------------------------
* - Removed the unnecessary "ReservePlugin" function.
* - Added a failsafe after plugins are supposed to be unloaded, as we've seen some cases where this plugin would be the only one refusing to unload, thus never refreshing the plugins.
* - Added a less messy way of preventing double pushing, as this plugin is the only one that could possibly be double pushed. (StrEqual instead of FindInArray for every single plugin)
*
*
* v1.2.1
* ------------------------
* ------- Details: -------
* ------------------------
* - Removed the unnecessary "ReservePlugin" function.
* - Added a failsafe after plugins are supposed to be unloaded, as we've seen some cases where this plugin would be the only one refusing to unload, thus never refreshing the plugins.
* - Added a less messy way of preventing double pushing, as this plugin is the only one that could possibly be double pushed. (StrEqual instead of FindInArray for every single plugin)
*
* v1.2.2
* ------------------------
* ------- Details: -------
* ------------------------
* - Added sPlugin which will store this plugin's path on load, rather than looking it up during the "UnloadPlugins" function.
* - Added Timers for closing functionality of UnloadPlugins to ensure accuracy.
*
* v1.2.3
* ------------------------
* - Unload commands are now issued in small batches (BATCH_SIZE per batch + a sentinel command)
*   instead of one big burst of ~150 commands. The burst could overflow the engine command buffer;
*   the dropped tail was then replayed late by command_buffer.smx AFTER "sm plugins refresh" had
*   already run, silently unloading early-loaded plugins (left4dhooks.smx etc.) with no log entry.
*
* v1.2.4
* ------------------------
* - The finishing step ("sm plugins refresh") is now issued in-line through the sentinel chain
*   instead of by a frame timer. Timers need a running frame loop; if the empty server stalls or
*   hibernates before they fire, the reload is silently lost and the server is left with no mode,
*   no watchdog and no base commands ("only this plugin is left on the server").
* - This plugin no longer unloads itself: it stays in memory as the last survivor, clears its
*   list on every run, and keeps sv_hibernate_when_empty pinned to 0 while loaded.
*
***************************************************************************************************************************************************************************************************
* ------------------------
* -------- NOTES: --------
* ------------------------
* - The plugin doesn't currently care about capitalization other than the Directory of the plugin, not sure if I can be bothered adding this :P
*
******************************************************************/

#define BATCH_SIZE 20 // Safe margin: the engine command buffer fit ~127 unload commands before overflowing.

Handle aReservedPlugins;
char sPlugin[PLATFORM_MAX_PATH];

int g_iUnloadCursor = -1;
bool g_bUnloading = false;

ConVar g_hHibernate = null;
bool   g_bNoHibIgnore = false;

public Plugin myinfo = 
{
	name = "Predictable Plugin Unloader",
	author = "Sir (heavily influenced by keyCat)",
	version = "1.2.4",
	description = "Allows for unloading plugins from last to first."
}

public void OnPluginStart()
{
	RegServerCmd("pred_unload_plugins", UnloadPlugins, "Unload Plugins!");
	RegServerCmd("pred_unload_continue", ContinueUnload, "Continue the batched unload. (Internal)");

	// Gotta reserve ourself of course.
	// - Supports moving the plugin to another folder. (INVALID_HANDLE simply gets the calling plugin)
	GetPluginFilename(INVALID_HANDLE, sPlugin, sizeof(sPlugin));

	// Reserved Plugins
	aReservedPlugins = CreateArray(PLATFORM_MAX_PATH);

	EnforceNoHibernate();
}

Action UnloadPlugins(int args) 
{
	// Fresh list each run (this plugin stays loaded between teardowns).
	ClearArray(aReservedPlugins);

	char stockpluginname[64];
	Handle pluginIterator = GetPluginIterator();
	Handle currentPlugin;

	while (MorePlugins(pluginIterator))
	{
		currentPlugin = ReadPlugin(pluginIterator);
		GetPluginFilename(currentPlugin, stockpluginname, sizeof(stockpluginname));

		// We don't push this plugin itself: it stays loaded as the last survivor (see v1.2.4).
		if (!StrEqual(sPlugin, stockpluginname)) 
		  PushArrayString(aReservedPlugins, stockpluginname);
	}

	CloseHandle(currentPlugin); // This one I probably don't have to close, but whatevs.
	CloseHandle(pluginIterator);

	ServerCommand("sm plugins load_unlock");

	// Issue the unloads in small batches. Dumping all ~150 "sm plugins unload" commands at once
	// could overflow the engine command buffer; the dropped tail was replayed late by command_buffer.smx
	// after "sm plugins refresh" had already run, silently unloading early-loaded plugins
	// (left4dhooks.smx and friends) with no log entry.
	g_iUnloadCursor = GetArraySize(aReservedPlugins);
	g_bUnloading = true;
	IssueUnloadBatch();

	return Plugin_Handled;
}

void IssueUnloadBatch()
{
	char sReserved[PLATFORM_MAX_PATH];

	for (int iIssued = 0; iIssued < BATCH_SIZE && g_iUnloadCursor > 0; iIssued++)
	{
		g_iUnloadCursor--; // Unload from last loaded to first loaded.
		GetArrayString(aReservedPlugins, g_iUnloadCursor, sReserved, sizeof(sReserved));
		ServerCommand("sm plugins unload %s", sReserved);
	}

	// The command buffer executes in order, so this sentinel runs only after the batch above is done.
	ServerCommand("pred_unload_continue");
}

Action ContinueUnload(int args)
{
	if (!g_bUnloading)
		return Plugin_Handled;

	if (g_iUnloadCursor > 0)
	{
		IssueUnloadBatch();
		return Plugin_Handled;
	}

	// Final phase: every unload command has executed by now (sentinel ordering guarantees it).
	// Reload the root plugin set in-line through the command buffer - NOT via a frame timer,
	// because a timer needs a running frame loop: if the empty server stalls or hibernates before
	// it fires, the reload is silently lost (no mode, no watchdog, no base commands - v1.2.4 fix).
	g_bUnloading = false;
	ServerCommand("sm plugins refresh");

	return Plugin_Handled;
}

// Keep "no hibernation when empty" enforced while this plugin is loaded. The mode teardown unloads
// every other plugin (including the watchdog) before the root set is reloaded - if hibernation were
// allowed in that window, SourceMod timers would freeze and nothing would ever come back.
void EnforceNoHibernate()
{
	if (g_hHibernate == null)
	{
		g_hHibernate = FindConVar("sv_hibernate_when_empty");
		if (g_hHibernate == null)
			return;

		HookConVarChange(g_hHibernate, OnHibernateChanged);
	}

	if (g_hHibernate.IntValue != 0)
	{
		g_bNoHibIgnore = true;
		g_hHibernate.SetInt(0);
		g_bNoHibIgnore = false;
	}
}

public void OnHibernateChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (g_bNoHibIgnore || convar.IntValue == 0)
		return;

	g_bNoHibIgnore = true;
	convar.SetInt(0);
	g_bNoHibIgnore = false;
}
