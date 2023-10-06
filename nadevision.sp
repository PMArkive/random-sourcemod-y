#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

enum ObsMode
{
	OBS_MODE_NONE = 0,	// not in spectator mode
	OBS_MODE_DEATHCAM,	// special mode for death cam animation
	OBS_MODE_FREEZECAM,	// zooms to a target, and freeze-frames on them
	OBS_MODE_FIXED,		// view from a fixed camera position
	OBS_MODE_IN_EYE,	// follow a player in first person view
	OBS_MODE_CHASE,		// follow a player in third person view
	OBS_MODE_POI,		// PASSTIME point of interest - game objective, big fight, anything interesting; added in the middle of the enum due to tons of hard-coded "<ROAMING" enum compares
	OBS_MODE_ROAMING	// free roaming
};

// sqrt(2 * sv_gravity * height) where height = 57
const float JUMP_VELOCITY = 301.993377411;

// Max player collisions in a tick.
const int MAX_PLAYER_COLLISIONS = 4;

// Player bounding box sizes.
float STAND_MIN[] = { -16.0, -16.0, 72.0 };
float STAND_MAX[] = { 16.0, 16.0, 72.0 };
float CROUCH_MIN[] = { -16.0, -16.0, 54.0 };
float CROUCH_MAX[] = { 16.0, 16.0, 54.0 };

// m_vecViewOffset Z values.
const float STAND_VIEW_HEIGHT = 64.062561;
const float CROUCH_VIEW_HEIGHT = 46.044968;

// Think interval for grenades to check for detonation.
const float NADE_THINK_TIME = 0.2;

// Time between releasing attack buttons and grenade spawning.
const float NADE_THROW_TIME = 0.1;

// The speed at which a nade is considered to be stopped by the game.
const float NADE_STOP_SPEED = 0.1;

// Max amount of time a simulated grenade can be stuck for before abandoning.
const float MAX_STUCK_TIME = 3.0;

// Grenade hull size.
const float NADE_SIZE = 2.0;
float NADE_MIN[] = { -NADE_SIZE, -NADE_SIZE, -NADE_SIZE };
float NADE_MAX[] = { NADE_SIZE, NADE_SIZE, NADE_SIZE };

// Grenade collision mask.
const int MASK_NADE = MASK_SOLID | CONTENTS_CURRENT_90;

// The highest possible surface normal Z that is not considered a floor by physics.
const float PHYS_FLOOR_Z = 0.7;

// Z offset for the starting point of inferno spawn traces.
const float MOLLY_Z_OFFSET = 10.0;

// Maximum height for molotovs/incendiaries to create an inferno.
const float MOLLY_MAX_HEIGHT = 128.0;

// Duration of smoke grenade particles.
const float SMOKE_DURATION = 20.0;

// How long it takes for a smokegrenade_projectile to be removed after detonating.
const float SMOKE_DELETE_TIME = 15.5;

// Impact cross colors, indexed by bounce count.
const int CROSS_COLOR_COUNT = 6;

int CROSS_COLORS[][4] = {
	{ 255, 128, 128, 255 },
	{ 255, 255, 128, 255 },
	{ 128, 255, 128, 255 },
	{ 128, 255, 255, 255 },
	{ 128, 128, 255, 255 },
	{ 255, 128, 255, 255 }
};

// Remote view camera hull size.
const float CAMERA_SIZE = 2.0;
float CAMERA_MIN[] = { -CAMERA_SIZE, -CAMERA_SIZE, -CAMERA_SIZE };
float CAMERA_MAX[] = { CAMERA_SIZE, CAMERA_SIZE, CAMERA_SIZE };

// Whether a player has nade vision disabled.
bool g_VisionDisabled[MAXPLAYERS + 1];

// Whether a player has automatic jump throws enabled.
bool g_AutoEnabled[MAXPLAYERS + 1];

// Next grenade trajectory draw time in ticks for each player.
int g_NextDrawTime[MAXPLAYERS + 1];

// Tick on which the currently thrown grenade will spawn.
int g_ReleaseTick[MAXPLAYERS + 1];

// Last CUserCmd::buttons of each player.
int g_LastButtons[MAXPLAYERS + 1];

// Whether a player has jump throw mode enabled.
bool g_JumpThrowEnabled[MAXPLAYERS + 1];

// Whether a player's IN_DUCK input should be removed until they release it.
bool g_RemoveDuck[MAXPLAYERS + 1];

// Whether a player is performing an automatic duck jump throw.
bool g_DuckJumpThrow[MAXPLAYERS + 1];

// Whether a player has nade throw info printing enabled.
bool g_NadePrintEnabled[MAXPLAYERS + 1];

// Whether a player should duckjumpthrow when crouching in jump throw mode.
bool g_DuckJumpEnabled[MAXPLAYERS + 1];

// The entity used as m_hObserverTarget when remote viewing.
int g_CameraTarget[MAXPLAYERS + 1];

// Players' eye angles before using remote viewing.
float g_OriginalEyeAngles[MAXPLAYERS + 1][3];

// Position of remote view camera.
float g_CameraPos[MAXPLAYERS + 1][3];

// Velocity of remote view camera.
float g_CameraVel[MAXPLAYERS + 1][3];

// Players' last projected grenade detonation point.
float g_LastNadeEndPos[MAXPLAYERS + 1][3];

// Materials used to draw nade trails.
int g_NadeTrailNoZ, g_NadeTrailZ;

// Timer to display help messages in chat.
Handle g_HelpTimer;

// Game cvars.
ConVar sv_cheats;
ConVar sv_gravity;
ConVar molotov_throw_detonate_time;
ConVar weapon_molotov_maxdetonateslope;
//ConVar inferno_surface_offset;
//ConVar inferno_max_range;

// Plugin cvars.
ConVar sm_nadevision;
ConVar sm_nadevision_help_timer;
ConVar sm_nadevision_debug;
ConVar sm_nadevision_ignorez;
ConVar sm_nadevision_global;
ConVar sm_nadevision_interval;
ConVar sm_nadevision_spacing;
ConVar sm_nadevision_width;
ConVar sm_nadevision_dashed;
ConVar sm_nadevision_cross_size;
ConVar sm_nadevision_cap_size;
ConVar sm_nadevision_smoke_time;
ConVar sm_nadevision_cam_height;
ConVar sm_nadevision_cam_speed;
ConVar sm_nadevision_cam_accel;
ConVar sm_nadevision_cam_decel;
ConVar sm_nadevision_cam_stopspeed;

public Plugin myinfo = 
{
	name = "NadeVision",
	author = "Altimor",
	description = "Displays predicted grenade trajectory.",
	version = "2.5.4",
	url = ""
};

const int NADE_NAME_LEN = 32;

enum struct NadeType
{
	char className[NADE_NAME_LEN]; // weapon_*
	char shortName[NADE_NAME_LEN]; // Used for cvar names.
	char longName[NADE_NAME_LEN]; // Used for cvar descriptions.

	// A fuseTime of 0 means the grenade detonates when its speed falls below 1 in/s.
	float fuseTime; // Natural detonation time, accurate to a 200ms Think.
	bool isFire; // Molotov/Incendiary.
	bool stopDetonate; // Smoke/Decoy.

	int color[4]; // Cached color cvar values.

	ConVar cvColor; // Color of trail segments and ring.
	ConVar cvFadeTime; // Time for trail segments to linger after the nade passes them.
	ConVar cvRingTime; // Time for the ring to linger after the nade detonates.
	ConVar cvRingSize; // Size of detonation ring.

	void Init(
		const char[] className,
		const char[] shortName,
		const char[] longName,
		float fuseTime,
		bool isFire,
		bool stopDetonate,
		int colorR,
		int colorG,
		int colorB,
		int colorA,
		float fadeTime,
		float ringTime,
		float ringSize)
	{
		strcopy(this.className, NADE_NAME_LEN, className);
		strcopy(this.shortName, NADE_NAME_LEN, shortName);
		strcopy(this.longName, NADE_NAME_LEN, longName);
		this.fuseTime = fuseTime;
		this.isFire = isFire;
		this.stopDetonate = stopDetonate;

		const int NAME_LEN = 64, DESC_LEN = 256, VALUE_LEN = 32;
		char name[NAME_LEN], desc[DESC_LEN], value[VALUE_LEN];

		Format(name, NAME_LEN, "sm_nadevision_%s_color", this.shortName);
		Format(desc, DESC_LEN, "Color of the %s's predicted path.", this.longName);
		Format(value, VALUE_LEN, "%i %i %i %i", colorR, colorG, colorB, colorA);
		this.cvColor = CreateConVar(name, value, desc, FCVAR_NOTIFY | FCVAR_DONTRECORD);
		this.cvColor.AddChangeHook(OnNadeColorChanged);

		// Immediately update the cached colors since the cvar may already exist.
		this.cvColor.GetString(value, VALUE_LEN);
		this.UpdateColor(value);

		Format(name, NAME_LEN, "sm_nadevision_%s_fade_time", this.shortName);
		Format(desc, DESC_LEN, "Number of seconds for trail segments to linger after the %s reaches them.", this.longName);
		Format(value, VALUE_LEN, "%f", fadeTime);
		this.cvFadeTime = CreateConVar(name, value, desc, FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);

		Format(name, NAME_LEN, "sm_nadevision_%s_ring_time", this.shortName);
		Format(desc, DESC_LEN, "Number of seconds for the ring to linger after the %s detonates.", this.longName);
		Format(value, VALUE_LEN, "%f", ringTime);
		this.cvRingTime = CreateConVar(name, value, desc, FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);

		Format(name, NAME_LEN, "sm_nadevision_%s_ring_size", this.shortName);
		Format(desc, DESC_LEN, "Size of the ring at the %s's detonation point.", this.longName);
		Format(value, VALUE_LEN, "%f", ringSize);
		this.cvRingSize = CreateConVar(name, value, desc, FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);
	}

	void GetFuseTime(float &result)
	{
		if (this.isFire)
			result = molotov_throw_detonate_time.FloatValue;
		else
			result = this.fuseTime;
	}

	void GetColor(int color[4])
	{
		color[0] = this.color[0];
		color[1] = this.color[1];
		color[2] = this.color[2];
		color[3] = this.color[3];
	}
	
	// Update the cached color values.
	void UpdateColor(const char[] newValue)
	{
		char components[4][16];
		ExplodeString(newValue, " ", components, 4, 16);

		bool clamped = false;
		for (int i = 0; i < 4; i++)
		{
			int value = StringToInt(components[i]);
			if (value >= 0 && value <= 255)
			{
				this.color[i] = value;
				continue;
			}

			this.color[i] = value < 0 ? 0 : 255;
			clamped = true;
		}

		if (!clamped)
			return;

		// Update the cvar with the clamped values.
		char newString[64];
		Format(newString, 64, "%i %i %i %i", this.color[0], this.color[1], this.color[2], this.color[3]);
		this.cvColor.SetString(newString);
	}
};

enum NadeTypeId
{
	NADE_HE = 0,
	NADE_Flash = 1,
	NADE_Smoke = 2,
	NADE_Molly = 3,
	NADE_Inc = 4,
	NADE_Decoy = 5
};

const int NADE_Max = 6;

NadeType g_Nades[NadeTypeId];

public void OnPluginStart()
{
	if (GetEngineVersion() != Engine_CSGO)
		SetFailState("NadeVision is incompatible with games other than CSGO.");

	sv_cheats = FindConVar("sv_cheats");
	sv_gravity = FindConVar("sv_gravity");
	molotov_throw_detonate_time = FindConVar("molotov_throw_detonate_time");
	weapon_molotov_maxdetonateslope = FindConVar("weapon_molotov_maxdetonateslope");
	//inferno_surface_offset = FindConVar("inferno_surface_offset");
	//inferno_max_range = FindConVar("inferno_max_range");

	sm_nadevision = CreateConVar("sm_nadevision", "1", "Enable grenade trajectory prediction.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0, true, 1.0);
	sm_nadevision_help_timer = CreateConVar("sm_nadevision_help_timer", "120", "Time in between global help messages. 0 disables.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);
	sm_nadevision_debug = CreateConVar("sm_nadevision_debug", "0", "Enable debug spew for grenade simulation.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0, true, 1.0);
	sm_nadevision_ignorez = CreateConVar("sm_nadevision_ignorez", "1", "Whether to draw grenade trails through walls.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0, true, 1.0);
	sm_nadevision_global = CreateConVar("sm_nadevision_global", "0", "If enabled, trails will be visible to all players.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0, true, 1.0);
	sm_nadevision_interval = CreateConVar("sm_nadevision_interval", "0.078125", "Interval between grenade trail updates.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);
	sm_nadevision_spacing = CreateConVar("sm_nadevision_spacing", "10", "Minimum distance between TE beams in trails.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);
	sm_nadevision_width = CreateConVar("sm_nadevision_width", "0.5", "Width of grenade trajectory trail.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);
	sm_nadevision_dashed = CreateConVar("sm_nadevision_dashed", "1", "Whether the grenade trail should be dashed or solid.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0, true, 1.0);
	sm_nadevision_cross_size = CreateConVar("sm_nadevision_cross_size", "5", "Impact cross size in distance from center per axis.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);
	sm_nadevision_cap_size = CreateConVar("sm_nadevision_cap_size", "0.25", "Size of the caps at the beginning and end of the trail.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);
	sm_nadevision_smoke_time = CreateConVar("sm_nadevision_smoke_time", "20", "Adjusts the duration that smoke grenade particles appear for.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);
	sm_nadevision_cam_height = CreateConVar("sm_nadevision_cam_height", "24", "Adjusts the default height of the remote view camera.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);
	sm_nadevision_cam_speed = CreateConVar("sm_nadevision_cam_speed", "700", "Adjusts the max speed of the remote view camera.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);
	sm_nadevision_cam_accel = CreateConVar("sm_nadevision_cam_accel", "0.7", "Adjusts the accel per unit of speed per second of the remote view camera.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);
	sm_nadevision_cam_decel = CreateConVar("sm_nadevision_cam_decel", "2.0", "Adjusts the decel per unit of speed per second of the remote view camera.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);
	sm_nadevision_cam_stopspeed = CreateConVar("sm_nadevision_cam_stopspeed", "150", "Adjusts the minimum speed for speed based deceleration scaling.", FCVAR_NOTIFY | FCVAR_DONTRECORD, true, 0.0);

	g_HelpTimer = CreateTimer(sm_nadevision_help_timer.FloatValue, HelpTimer, _, TIMER_REPEAT);
	sm_nadevision_help_timer.AddChangeHook(OnHelpTimerChanged);

	AddCommandListener(BlockSpecMode, "spec_mode");

	g_Nades[NADE_HE].Init("weapon_hegrenade", "he", "H.E. grenade", 1.5, false, false, 255, 128, 0, 255, 3.0, 3.0, 64.0);
	g_Nades[NADE_Flash].Init("weapon_flashbang", "flash", "flashbang", 1.5, false, false, 0, 255, 0, 255, 3.0, 3.0, 30.0);
	g_Nades[NADE_Smoke].Init("weapon_smokegrenade", "smoke", "smoke grenade", 1.5, false, true, 0, 255, 255, 255, 5.0, 17.5, 250.0);
	g_Nades[NADE_Molly].Init("weapon_molotov", "molly", "molotov", 0.0, true, false, 255, 0, 0, 255, 3.0, 7.0, 120.0);
	g_Nades[NADE_Inc].Init("weapon_incgrenade", "inc", "incendiary", 0.0, true, false, 255, 0, 0, 255, 3.0, 7.0, 120.0);
	g_Nades[NADE_Decoy].Init("weapon_decoy", "decoy", "decoy grenade", 3.0, false, true, 255, 0, 255, 255, 5.0, 17.5, 250.0);

	AutoExecConfig(true, "nadevision");
}

public void OnMapStart()
{
	g_NadeTrailNoZ = PrecacheModel("materials/vgui/white.vmt");
	g_NadeTrailZ = PrecacheModel("materials/debug/debugvertexcolor.vmt");
}

public void OnClientPutInServer(int client)
{
	// Initialize per client globals.
	g_VisionDisabled[client] = false;
	g_AutoEnabled[client] = false;
	g_NextDrawTime[client] = 0;
	g_ReleaseTick[client] = 0;
	g_JumpThrowEnabled[client] = false;
	g_LastButtons[client] = 0;
	g_DuckJumpThrow[client] = false;
	g_NadePrintEnabled[client] = true;
	g_DuckJumpEnabled[client] = false;
	g_CameraTarget[client] = 0;
}

public void OnClientDisconnect(int client)
{
	// Remove a client's freelook target when they disconnect.
	int target = g_CameraTarget[client];
	if (target != 0)
		RemoveEntity(target);

	g_CameraTarget[client] = 0;
}

public Action OnClientSayCommand(int client, const char[] command, const char[] sArgs)
{
	if (StrEqual(sArgs, ".nadevision") || StrEqual(sArgs, ".altimor"))
	{
		PrintToChat(client, " \x10[NadeVision]\x01 Prime a grenade to view its trajectory.");
		PrintToChat(client, " \x10[NadeVision]\x01 Type \x04.shownades\x01 to toggle trajectory display.");
		PrintToChat(client, " \x10[NadeVision]\x01 Type \x04.nadeprint\x01 to toggle throw info console printing.");
		if (sv_cheats.BoolValue)
		{
			PrintToChat(client, " \x10[NadeVision]\x01 If you can't see the entire nade trajectory, it may help to");
			PrintToChat(client, "use \x0Csv_force_transmit_ents 1\x01 with \x0Cr_novis 1\x01 or \x0Cr_lockpvs 1\x01.");
		}
		PrintToChat(client, " \x10[NadeVision]\x01 Press \x02USE\x01 while priming to toggle jump throw mode.");
		PrintToChat(client, "Jump throws will be predicted and can be automated.");
		PrintToChat(client, " \x10[NadeVision]\x01 Press \x02RELOAD\x01 while priming to toggle remote viewing.");
		PrintToChat(client, "A controllable remote camera will be created at the detonation point and you will be frozen in place.");
		PrintToChat(client, " \x10[NadeVision]\x01 Type \x04.autothrow\x01 to toggle automatic jump throws.");
		PrintToChat(client, " \x10[NadeVision]\x01 Type \x04.duckjump\x01 to enable duck jump throws.");
		PrintToChat(client, "Holding \x02DUCK\x01 while in jump throw mode will simulate");
		PrintToChat(client, "inputting duck+jump on the same tick and releasing duck before");
		PrintToChat(client, "the grenade is spawned.");
		return Plugin_Handled;
	}
	else if (StrEqual(sArgs, ".shownades"))
	{
		bool enabled = !(g_VisionDisabled[client] = !g_VisionDisabled[client]);
		PrintToChat(client, " \x10[NadeVision]\x01 Trajectory display %s\x01.", enabled ? "\x04ON" : "\x02OFF"); 
		return Plugin_Handled;
	}
	else if (StrEqual(sArgs, ".nadeprint"))
	{
		bool enabled = g_NadePrintEnabled[client] = !g_NadePrintEnabled[client];
		PrintToChat(client, " \x10[NadeVision]\x01 Throw info printing %s\x01.", enabled ? "\x04ON" : "\x02OFF"); 
		return Plugin_Handled;
	}
	else if (StrEqual(sArgs, ".autothrow"))
	{
		bool enabled = g_AutoEnabled[client] = !g_AutoEnabled[client];
		PrintToChat(client, " \x10[NadeVision]\x01 Automatic jump throws %s\x01.", enabled ? "\x04ON" : "\x02OFF"); 
		return Plugin_Handled;
	}
	else if (StrEqual(sArgs, ".duckjump"))
	{
		bool enabled = g_DuckJumpEnabled[client] = !g_DuckJumpEnabled[client];
		PrintToChat(client, " \x10[NadeVision]\x01 Duck jump throw %s\x01.", enabled ? "\x04ON" : "\x02OFF"); 
		if (enabled)
			PrintToChat(client, "Hold \x02DUCK\x01 while in jump throw mode to use.");

		return Plugin_Handled;
	}

	return Plugin_Continue;
}

// Hook smoke grenades' ThinkPost to set the fade time on detonation.
public void OnEntityCreated(int entity, const char[] classname)
{
	if (!StrEqual(classname, "smokegrenade_projectile"))
		return;

	SDKHook(entity, SDKHook_ThinkPost, SmokeThinkPost);
}

// Set the fade time on smokes.
void SmokeThinkPost(int entity)
{
	if (!GetEntProp(entity, Prop_Send, "m_bDidSmokeEffect"))
		return;
	
	// Change m_nSmokeEffectTickBegin based on the difference between the
	// normal smoke duration and the cvar.
	float timeDifference = sm_nadevision_smoke_time.FloatValue - SMOKE_DURATION;

	if (timeDifference != 0.0)
	{
		int serverTick = RoundToNearest(GetGameTime() / GetTickInterval());
		int newBegin = serverTick + RoundToNearest(timeDifference / GetTickInterval());
		SetEntProp(entity, Prop_Send, "m_nSmokeEffectTickBegin", newBegin);

		// Adjust the smokegrenade_projectile deletion time.
		// This controls the grey overlay when walking through the smoke.
		float deleteTime = timeDifference + SMOKE_DELETE_TIME;
		CreateTimer(deleteTime, RemoveSmoke, entity);
	}

	SDKUnhook(entity, SDKHook_ThinkPost, SmokeThinkPost);
}

Action RemoveSmoke(Handle timer, int entity)
{
	RemoveEntity(entity);
}

// Block spec_mode when in remote viewing mode.
Action BlockSpecMode(int client, const char[] command, int argc)
{
	return g_CameraTarget[client] != 0 ? Plugin_Handled : Plugin_Continue;
}

// Set the cached color values for a nade when the cvar is changed.
void OnNadeColorChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	for (int type = 0; type < NADE_Max; type++)
	{
		if (g_Nades[type].cvColor == convar)
		{
			g_Nades[type].UpdateColor(newValue);
			return;
		}
	}
}

Action HelpTimer(Handle timer, any data)
{
	PrintToChatAll(" \x10[NadeVision]\x01 Type \x04.nadevision\x01 or \x04.altimor\x01 for help.");
	return Plugin_Continue;
}

void OnHelpTimerChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if (g_HelpTimer != null)
	{
		g_HelpTimer.Close();
		g_HelpTimer = null;
	}

	if (convar.FloatValue > 0.0)
		g_HelpTimer = CreateTimer(convar.FloatValue, HelpTimer, _, TIMER_REPEAT);
}

// Custom GetClientEyeAngles that retrieves the original eye angles when remote viewing.
void NadeGetClientEyeAngles(int client, float angles[3])
{
	if (g_CameraTarget[client] == 0)
		GetClientEyeAngles(client, angles);
	else
		angles = g_OriginalEyeAngles[client];
}

// Filter out all players and grenade projectiles.
bool TraceFilter(int entity, int contentsMask, int data)
{
	if (entity >= 1 || entity <= MaxClients)
		return false;

	char classname[256];
	if (!GetEntityClassname(entity, classname, 256))
		return true;

	return !StrEqual(classname, "hegrenade_projectile")
		&& !StrEqual(classname, "flashbang_projectile")
		&& !StrEqual(classname, "smokegrenade_projectile")
		&& !StrEqual(classname, "molotov_projectile")
		&& !StrEqual(classname, "decoy_projectile");
}

// Perform a collision trace for a grenade.
Handle TraceGrenade(const float start[3], const float end[3])
{
	return TR_TraceHullFilterEx(
		start,
		end,
		NADE_MIN,
		NADE_MAX,
		MASK_NADE,
		TraceFilter);
}

// Perform a collision trace for the remote view camera.
Handle TraceCamera(const float start[3], const float end[3])
{
	return TR_TraceHullFilterEx(
		start,
		end,
		CAMERA_MIN,
		CAMERA_MAX,
		MASK_SOLID,
		TraceFilter);
}

// Perform a collision trace for a player.
Handle TracePlayer(const float start[3], const float end[3], bool ducking)
{
	return TR_TraceHullFilterEx(
		start,
		end,
		ducking ? CROUCH_MIN : STAND_MIN,
		ducking ? CROUCH_MAX : STAND_MAX,
		MASK_PLAYERSOLID,
		TraceFilter);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float move[3], float viewangles[3])
{
	int lastButtons = g_LastButtons[client];
	int realButtons = g_LastButtons[client] = buttons;
	bool duckJumpThrow = g_DuckJumpThrow[client];

	if (!(buttons & IN_DUCK))
		g_RemoveDuck[client] = false;
	else if (g_RemoveDuck[client])
		buttons &= ~IN_DUCK;

	UpdateDuckJumpThrowProgress(client, buttons, lastButtons);

	if (!sm_nadevision.BoolValue || g_VisionDisabled[client])
	{
		RestoreCamera(client, viewangles);
		return Plugin_Continue;
	}

	int weapon = GetEntPropEnt(client, Prop_Data, "m_hActiveWeapon");
	if (weapon == -1)
	{
		RestoreCamera(client, viewangles);
		return Plugin_Continue;
	}

	// Use the corrected client clock.
	int tickBase = GetEntProp(client, Prop_Send, "m_nTickBase");

	// Get grenade attributes.
	NadeTypeId nadeTypeId;
	if (!InitGrenade(client, weapon, tickBase, nadeTypeId))
	{
		RestoreCamera(client, viewangles);
		return Plugin_Continue;
	}

	// Let the player toggle jumpthrow mode and use auto-jumpthrow.
	if (!duckJumpThrow)
		UpdateJumpThrow(client, buttons, realButtons, lastButtons, tickBase);

	// Check if the player wants to remote view the detonation point.
	bool inRemoteView = false;
	bool pressedReload = (realButtons & IN_RELOAD) && !(lastButtons & IN_RELOAD);

	if (g_CameraTarget[client] != 0)
	{
		if (pressedReload)
		{
			RestoreCamera(client, viewangles);
		}
		else
		{
			// Continue updating m_hObserverTarget to ensure it isn't overwritten on the client.
			SetEntPropEnt(client, Prop_Send, "m_hObserverTarget", g_CameraTarget[client]);

			RemoteViewMove(client, buttons, move, viewangles);
			inRemoteView = true;
		}
	}
	else if (pressedReload)
	{
		RemoteView(client, g_LastNadeEndPos[client]);
		RemoteViewMove(client, buttons, move, viewangles);
		inRemoteView = true;
	}

	if (inRemoteView)
	{
		// Make them keep holding attack buttons since there's no way to
		// +attack or +attack2 while observing.
		int lastAttack = lastButtons & (IN_ATTACK | IN_ATTACK2);
		buttons |= lastAttack;
		g_LastButtons[client] |= lastAttack;
	}

	bool throwing, releasing;

	if (tickBase <= g_ReleaseTick[client])
	{
		// Already throwing.
		throwing = false;
		releasing = tickBase == g_ReleaseTick[client];
	}
	else
	{
		throwing = (buttons & (IN_ATTACK | IN_ATTACK2)) == 0;
		releasing = false;

		if (throwing)
		{
			int throwTicks = RoundToFloor(NADE_THROW_TIME / GetTickInterval()) + 2;
			g_ReleaseTick[client] = tickBase + throwTicks;
		}
	}

	// Check if it's time to redraw trails.
	if (tickBase < g_NextDrawTime[client] && !releasing)
		return Plugin_Continue;

	// Update the next draw time.
	int drawTicks = RoundToCeil(sm_nadevision_interval.FloatValue / GetTickInterval());
	g_NextDrawTime[client] = tickBase + drawTicks + 1;

	float nadePos[3], nadeVel[3];
	CalcGrenadeSpawn(client, weapon, realButtons, nadePos, nadeVel, tickBase);

	if (sm_nadevision_debug.BoolValue)
	{
		float eyePos[3];
		GetClientEyePosition(client, eyePos);

		PrintToConsole(client, "--- Grenade Start");
		PrintToConsole(client, "Weapon Entity      %i", weapon);
		PrintToConsole(client, "Grenade Type       %i", g_Nades[nadeTypeId].longName);
		PrintToConsole(client, "Initial Position   %f %f %f", nadePos[0], nadePos[1], nadePos[2]);
		PrintToConsole(client, "Initial Distance   %f", GetVectorDistance(eyePos, nadePos));
		PrintToConsole(client, "Initial Velocity   %f %f %f", nadeVel[0], nadeVel[1], nadeVel[2]);
		PrintToConsole(client, "Initial Speed      %f", GetVectorLength(nadeVel));
		PrintToConsole(client, "Throwing           %s", throwing ? "Yes" : "No");
		PrintToConsole(client, "Releasing          %s", releasing ? "Yes" : "No");
	}

	float travelTime = DrawGrenadeTrail(
		client,
		g_Nades[nadeTypeId],
		nadePos,
		nadeVel,
		releasing,
		tickBase);

	g_LastNadeEndPos[client] = nadePos;

	if (releasing && g_NadePrintEnabled[client])
	{
		// Print grenade throw information.
		float origin[3], angles[3], playerVel[3];
		GetClientAbsOrigin(client, origin);
		NadeGetClientEyeAngles(client, angles);
		GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", playerVel);

		float delta[3];
		SubtractVectors(origin, nadePos, delta);
		float dist2d = SquareRoot(delta[0] * delta[0] + delta[1] * delta[1]);
		float speed = SquareRoot(playerVel[0] * playerVel[0] + playerVel[1] * playerVel[1]);
		
		PrintToConsole(client, "--- Throw at t=%f", GetGameTime());
		PrintToConsole(client, "Player Pos  %f %f %f", origin[0], origin[1], origin[2]);
		PrintToConsole(client, "Player Vel  %f %f %f", playerVel[0], playerVel[1], playerVel[2]);
		PrintToConsole(client, "Player Spd  %f", speed);
		PrintToConsole(client, "Eye Angles  %f %f %f", angles[0], angles[1], angles[2]);
		PrintToConsole(client, "End Point   %f %f %f", nadePos[0], nadePos[1], nadePos[2]);
		PrintToConsole(client, "2D Distance %f", dist2d);
		PrintToConsole(client, "Height Diff %f", nadePos[2] - origin[2]); 
		PrintToConsole(client, "Travel Time %f", travelTime);
	 	PrintToConsole(client, "Strength    %f", GetEntPropFloat(weapon, Prop_Send, "m_flThrowStrength"));
		PrintToConsole(client, "setpos_exact %f %f %f; setang %f %f %f",
			origin[0], origin[1], origin[2],
			angles[0], angles[1], angles[2]);
	}

	return Plugin_Continue;
}

// If a camera target was created for this player, restore their view and delete the target.
void RestoreCamera(int client, float viewangles[3])
{
	int target = g_CameraTarget[client];
	if (g_CameraTarget[client] == 0)
		return;
	
	TeleportEntity(client, NULL_VECTOR, g_OriginalEyeAngles[client], NULL_VECTOR);
	viewangles = g_OriginalEyeAngles[client];

	// Remove the target and the parent created to force transmission.
	int parent = GetEntPropEnt(target, Prop_Data, "m_hParent");
	RemoveEntity(parent);
	RemoveEntity(target);

	SetEntProp(client, Prop_Data, "m_MoveType", MOVETYPE_WALK);
	SetEntProp(client, Prop_Send, "m_iObserverMode", OBS_MODE_NONE);
	SetEntPropEnt(client, Prop_Send, "m_hObserverTarget", -1);
	g_CameraTarget[client] = 0;
}
	
// Allow a client to remotely view a position.
void RemoteView(int client, const float pos[3])
{
	// Move a bit above the position.
	float camPos[3];
	camPos[0] = pos[0];
	camPos[1] = pos[1];
	camPos[2] = pos[2] + sm_nadevision_cam_height.FloatValue;

	// Check camera collision.
	Handle trace = TraceCamera(pos, camPos);
	TR_GetEndPosition(camPos, trace);
	trace.Close();

	GetClientEyeAngles(client, g_OriginalEyeAngles[client]);
	g_CameraVel[client][0] = g_CameraVel[client][1] = g_CameraVel[client][2] = 0.0;

	// Create a new camera target for this client.
	//
	// This is a hack for this:
	//
	// // If our target isn't visible, we're at a camera point of some kind.
	// // Instead of letting the player rotate around an invisible point, treat
	// // the point as a fixed camera.
	// if ( !target->GetBaseAnimating() && !target->GetModel() )
	int target = CreateEntityByName("prop_dynamic");
	DispatchKeyValue(target, "model", "models/editor/axis_helper_thick.mdl");
	DispatchKeyValue(target, "solid", "0");
	DispatchKeyValueFloat(target, "modelscale", 0.54);
	DispatchKeyValueVector(target, "origin", camPos);
	SDKHook(target, SDKHook_SetTransmit, RemoteViewTransmit);
	DispatchSpawn(target);

	// Force transmission with an FL_EDICT_ALWAYS parent.
	int parent = CreateEntityByName("info_target");
	SetEdictFlags(parent, GetEdictFlags(parent) | FL_EDICT_ALWAYS);
	DispatchSpawn(parent);
	SetVariantString("!activator");
	AcceptEntityInput(target, "SetParent", parent);

	SetEntProp(client, Prop_Data, "m_MoveType", MOVETYPE_NONE);
	SetEntProp(client, Prop_Send, "m_iObserverMode", OBS_MODE_CHASE);
	SetEntPropEnt(client, Prop_Send, "m_hObserverTarget", target);
	g_CameraTarget[client] = target;
	g_CameraPos[client] = camPos;
}

Action RemoteViewTransmit(int entity, int client)
{
	return g_CameraTarget[client] == entity ? Plugin_Continue : Plugin_Handled;
}

void RemoteViewAccelerate(int client, int buttons, const float move[3], const float viewangles[3])
{
	float velocity[3];
	float speed = GetVectorLength(move);
	velocity = g_CameraVel[client];

	if (speed == 0.0)
	{
		// Not moving, just decelerate.
		float decel = sm_nadevision_cam_decel.FloatValue * GetTickInterval();
		float length = GetVectorLength(velocity);
		float stopSpeed = sm_nadevision_cam_stopspeed.FloatValue;
		if (length > stopSpeed)
			decel *= length;
		else
			decel *= stopSpeed;

		if (decel >= length)
			velocity[0] = velocity[1] = velocity[2] = 0.0;
		else
			ScaleVector(velocity, (length - decel) / length);

		g_CameraVel[client] = velocity;
	}

	// Cap input vector speed to the cvar and allow walking.
	float maxSpeed = sm_nadevision_cam_speed.FloatValue;
	if (buttons & IN_SPEED)
		maxSpeed /= 3.0;

	// Rescale the input vector.
	speed *= maxSpeed / 450.0;

	if (speed > maxSpeed)
		speed = maxSpeed;

	// Rotate input vector based on viewangles.
	float moveFwd[3], moveRight[3], moveUp[3], moveDir[3];
	GetAngleVectors(viewangles, moveFwd, moveRight, moveUp);
	ScaleVector(moveFwd, move[0]);
	ScaleVector(moveRight, move[1]);
	ScaleVector(moveUp, move[2]);
	AddVectors(moveFwd, moveRight, moveDir);
	AddVectors(moveDir, moveUp, moveDir);
	NormalizeVector(moveDir, moveDir);

	// Split velocity into two components facing towards and away
	// from the target direction.
	float towardComponent[3], awayComponent[3];
	float moveDot = GetVectorDotProduct(velocity, moveDir);
	if (moveDot >= speed)
		moveDot = speed;

	if (moveDot <= 0.0)
	{
		towardComponent[0] = towardComponent[1] = towardComponent[2] = 0.0;
	}
	else
	{
		towardComponent = moveDir;
		ScaleVector(towardComponent, moveDot);
	}

	SubtractVectors(velocity, towardComponent, awayComponent);

	// Accelerate from player movement.
	float accelVec[3];
	float accel = sm_nadevision_cam_accel.FloatValue * speed * GetTickInterval();
	accelVec = moveDir;
	if (moveDot + accel >= speed)
		ScaleVector(accelVec, speed - moveDot);
	else
		ScaleVector(accelVec, accel);
	
	AddVectors(towardComponent, accelVec, towardComponent);

	// Decelerate if player isn't moving in this direction.
	float decel = sm_nadevision_cam_decel.FloatValue * GetTickInterval();
	float awayLength = GetVectorLength(awayComponent);
	float stopSpeed = sm_nadevision_cam_stopspeed.FloatValue;
	if (awayLength > stopSpeed)
		decel *= awayLength;
	else
		decel *= stopSpeed;

	if (decel >= awayLength)
		awayComponent[0] = awayComponent[1] = awayComponent[2] = 0.0;
	else
		ScaleVector(awayComponent, (awayLength - decel) / awayLength);

	// Update velocity.
	AddVectors(towardComponent, awayComponent, g_CameraVel[client]);
}

void RemoteViewMove(int client, int buttons, const float move[3], const float viewangles[3])
{
	RemoteViewAccelerate(client, buttons, move, viewangles);

	float startPos[3];
	startPos = g_CameraPos[client];

	float velocity[3];
	velocity = g_CameraVel[client];

	// Collide and slide.
	float endPos[3];
	float timeSlice = 1.0;

	for (int i = 0; i < MAX_PLAYER_COLLISIONS; i++)
	{
		float delta[3];
		delta = velocity;
		ScaleVector(delta, GetTickInterval() * timeSlice);

		float deltaLength = GetVectorLength(delta);
		if (deltaLength == 0.0)
		{
			endPos = startPos;
			break;
		}

		AddVectors(startPos, delta, endPos);

		// Start 10 units back to avoid clipping through displacements.
		float newStartPos[3];
		NormalizeVector(delta, newStartPos);
		ScaleVector(newStartPos, -10.0);
		AddVectors(newStartPos, startPos, newStartPos);
		Handle trace = TraceCamera(startPos, newStartPos);

		float startPosDelta = TR_GetFraction(trace) * 10.0;
		TR_GetEndPosition(newStartPos, trace);
		trace.Close();

		trace = TraceCamera(newStartPos, endPos);

		float totalLength = deltaLength + startPosDelta;
		float fraction = (TR_GetFraction(trace) * totalLength - startPosDelta) / deltaLength;

		if (!TR_DidHit(trace))
		{
			trace.Close();
			break;
		}

		// Clip velocity.
		float impulse[3];
		TR_GetPlaneNormal(trace, impulse);
		ScaleVector(impulse, GetVectorDotProduct(velocity, impulse));
		SubtractVectors(velocity, impulse, velocity);

		// Move for the rest of the tick.
		if (fraction > 0.0)
		{
			timeSlice *= 1.0 - fraction;
			TR_GetEndPosition(startPos, trace);
		}
		trace.Close();
	}

	g_CameraVel[client] = velocity;
	g_CameraPos[client] = endPos;
	TeleportEntity(g_CameraTarget[client], endPos, NULL_VECTOR, NULL_VECTOR);
}

// Allow a player to toggle jumpthrow mode with IN_USE.
// Automatically jumpthrow and duckjumpthrow when in jumpthrow mode.
void UpdateJumpThrow(int client, int &buttons, int realButtons, int lastButtons, int tickBase)
{
	bool enabled = g_JumpThrowEnabled[client];

	if ((realButtons & IN_USE) && !(lastButtons & IN_USE))
	{
		g_JumpThrowEnabled[client] = enabled = !enabled;
		PrintHintText(client, "[NadeVision] Jump throw %s", enabled ? "ON" : "OFF");
	}

	if (!g_AutoEnabled[client])
		return;

	// Check if already throwing.
	if (tickBase < g_ReleaseTick[client])
		return;

	int lastAttack = lastButtons & (IN_ATTACK | IN_ATTACK2);

	// Check if jumpthrowing.
	if (!enabled || (buttons & (IN_ATTACK | IN_ATTACK2)))
		return;

	if (!(realButtons & IN_DUCK) || !g_DuckJumpEnabled[client])
	{
		// Auto jumpthrow.
		buttons |= IN_JUMP;
		return;
	}

	if (!(lastButtons & IN_DUCK))
	{
		// Manual duckjumpthrow.
		return;
	}

	// Continue priming for a tick.
	buttons |= lastAttack;
	g_LastButtons[client] |= lastAttack;
	buttons &= ~(IN_JUMP | IN_DUCK);
	g_LastButtons[client] &= ~IN_DUCK;
	g_RemoveDuck[client] = true;
	g_DuckJumpThrow[client] = true;
}

// Handle duckjumpthrows that have already started.
void UpdateDuckJumpThrowProgress(int client, int &buttons, int lastButtons)
{
	if (!g_DuckJumpThrow[client])
		return;

	float duckAmount = GetEntPropFloat(client, Prop_Send, "m_flDuckAmount");

	if (lastButtons & IN_DUCK)
	{
		// Hold duck for an extra tick.
		buttons |= IN_DUCK;
		g_LastButtons[client] &= ~IN_DUCK;
		g_DuckJumpThrow[client] = false;
	}
	else if (duckAmount > 0.0)
	{
		// Delay until fully unducked.
		int lastAttack = lastButtons & (IN_ATTACK | IN_ATTACK2);
		buttons |= lastAttack;
		buttons &= ~(IN_JUMP | IN_DUCK);
		g_LastButtons[client] |= lastAttack;
		g_LastButtons[client] &= ~IN_DUCK;
	}
	else
	{
		// Auto duckjumpthrow.
		buttons |= IN_JUMP | IN_DUCK;
		buttons &= ~(IN_ATTACK | IN_ATTACK2);
		g_LastButtons[client] |= IN_DUCK;
	}

}

/*enum struct NadeSimulation
{
	NadeType type;

	int fuseTicks;
	int nextThink;

	float pos[3];
	float vel[3];
	int ticks;
	int bounces;
	bool detonated;

	void Init(NadeType type)
	{
		this.type = type;
		int thinkTicks = RoundToNearest(NADE_THINK_TIME / GetTickInterval());
		int fuseTicks = RoundToNearest(g_Nades[type].GetFuseTime() / GetTickInterval());
	}

	void Think()
	{
		// Detonate when speed falls below 1 in/s. (Smoke/Decoy)
		if (fuseTime == 0.0 && speedSqr < 1.0)
			detonated = true;
		else if (fuseTime != 0.0 && simTicks > fuseTicks)
			detonated = true;

		nextThink = ticks + RoundToNearest(NADE_THINK_TIME / GetTickInterval());
	}

	void Tick()
	{
		if (ticks == nextThink)
			Think();
	}
};*/

// Simulate each tick of the grenade's lifetime given its initial values
// and draw TE beams along its path. Returns the grenade's travel time.
float DrawGrenadeTrail(
	int client,
	NadeType nadeType,
	float nadePos[3],
	float nadeVel[3],
	bool persistent,
	int tickBase)
{
	float bouncePos[3], bounceNormal[3], lastDrawPos[3];
	bool detonated = false, stopped = false;
	int simTicks = 0, bounces = 0, stuckTicks = 0;

	float spacing = sm_nadevision_spacing.FloatValue;
	float spacingSqr = spacing * spacing;
	bool dashed = sm_nadevision_dashed.BoolValue;

	float fuseTime;
	nadeType.GetFuseTime(fuseTime);
	bool isFire = nadeType.isFire;
	bool stopDetonate = nadeType.stopDetonate;

	float fadeTime = nadeType.cvFadeTime.FloatValue;
	float ringTime = nadeType.cvRingTime.FloatValue;

	// When grenades are created in the weapon's ItemPostFrame, SetDetonateTimerLength and
	// SetNextThink are called using the client clock, but Thinks are checked and called
	// using the server clock.
	int serverTick = RoundToNearest(GetGameTime() / GetTickInterval());
	int clockOffset = tickBase - serverTick;

	// The first think won't happen on the same tick, so clock drift must be greater than a tick.
	int firstThink = clockOffset > 1 ? clockOffset - 1 : 0;
	int fuseTicks = RoundToFloor(fuseTime / GetTickInterval()) + clockOffset;
	int thinkTicks = RoundToNearest(NADE_THINK_TIME / GetTickInterval());

	int color[4];
	nadeType.GetColor(color);

	lastDrawPos = nadePos;

	for (;;)
	{
		float ringPos[3];

		// Check if stuck outside the world.
		if (TR_PointOutsideWorld(nadePos))
			break;

		// Fuses are checked from Think.
		if (simTicks >= firstThink
			&& (simTicks - firstThink) % thinkTicks == 0
			&& simTicks >= fuseTicks)
		{

			if (isFire)
			{
				detonated = true;
				ringPos[0] = nadePos[0];
				ringPos[1] = nadePos[1];
				ringPos[2] = nadePos[2] + MOLLY_Z_OFFSET;

				// Check if the fire can reach the ground.
				if (!MoveToGround(ringPos, MOLLY_MAX_HEIGHT + MOLLY_Z_OFFSET))
					break;
			}
			else if (!stopDetonate || GetVectorLength(nadeVel) <= NADE_STOP_SPEED)
			{
				detonated = true;
				ringPos = nadePos;
			}
		}

		if (stopped && !detonated)
		{
			// Nothing further to do except detonate.
			simTicks++;
			continue;
		}

		// Check if the grenade got stuck somewhere it can't detonate.
		if (GetVectorLength(nadeVel) <= NADE_STOP_SPEED)
		{
			int maxStuckTicks = RoundToNearest(MAX_STUCK_TIME/ GetTickInterval());
			if (stuckTicks++ > maxStuckTicks)
				break;
		}
		else
		{
			stuckTicks = 0;
		}

		int oldBounces = bounces;

		if (!detonated)
		{
			// Simulate a physics tick.
			TickGrenade(client, nadePos, nadeVel, bounces, bouncePos, bounceNormal, GetTickInterval());
			ringPos = nadePos;
		}

		bool bounced = bounces > oldBounces;

		// Draw persistent trails to match the grenade's travel,
		// otherwise draw for the update interval.
		float lifetime;
		if (persistent)
			lifetime = float(simTicks) * GetTickInterval() + fadeTime;
		else
			lifetime = sm_nadevision_interval.FloatValue;

		// Draw start cap.
		if (simTicks == 1)
			DrawCap(client, nadeType, lastDrawPos, nadePos, lifetime);

		if (bounced)
		{
			// Check for Molotov/Incendiary detonation.
			float minZ = Cosine(DegToRad(weapon_molotov_maxdetonateslope.FloatValue));
			if (isFire)
			{
				if (bounceNormal[2] >= minZ)
					detonated = true;
			}

			// Check if the nade completely stopped on a floor.
			if (bounceNormal[2] > PHYS_FLOOR_Z && GetVectorLength(nadeVel) <= NADE_STOP_SPEED)
				stopped = true;

			// Draw a cross showing the impact normal and always show
			// the exact bounce position.
			int colorIndex = oldBounces % CROSS_COLOR_COUNT;
			DrawCross(client, bouncePos, bounceNormal, CROSS_COLORS[colorIndex], lifetime);
			DrawTrailSegment(client, lastDrawPos, bouncePos, color, lifetime, dashed);
			lastDrawPos = bouncePos;
		}

		if (detonated)
		{
			// Always draw detonation point and draw end cap.
			DrawTrailSegment(client, lastDrawPos, nadePos, color, lifetime, dashed);
			DrawCap(client, nadeType, nadePos, lastDrawPos, lifetime);

			// Draw detonation ring.
			float ringLife;
			if (persistent)
				ringLife = float(simTicks) * GetTickInterval() + ringTime;
			else
				ringLife = lifetime;

			float ringSize = nadeType.cvRingSize.FloatValue;
			if (ringSize > 0.0)
				DrawRing(client, ringPos, ringSize, ringLife);

			break;
		}

		if (GetVectorDistance(nadePos, lastDrawPos, true) >= spacingSqr)
		{
			// Moved enough for a new TE.
			DrawTrailSegment(client, lastDrawPos, nadePos, color, lifetime, dashed);
			lastDrawPos = nadePos;
		}

		// Update time.
		simTicks++;
	}

	return simTicks * GetTickInterval();
}

// Send a temp ent to either the client or everyone depending on sm_nadevision_global.
void SendTempEnt(int client, float delay)
{
	if (sm_nadevision_global.BoolValue)
		TE_SendToAll(delay);
	else
		TE_SendToClient(client, delay);
}

// Get the material to draw grenade trails with.
int GetTrailMaterial()
{
	return sm_nadevision_ignorez.BoolValue ? g_NadeTrailNoZ : g_NadeTrailZ;
}

// Draw a cap (a square perpendicular to the trail) to show ends of the grenade trail.
void DrawCap(
	int client,
	NadeType nadeType,
	const float pos[3],
	const float towards[3],
	float lifetime)
{
	float size = sm_nadevision_cap_size.FloatValue;
	if (size <= 0.0)
		return;

	float direction[3];
	SubtractVectors(towards, pos, direction);
	NormalizeVector(direction, direction);

	float start[3], end[3], offset[3];
	GetVectorVectors(direction, offset, NULL_VECTOR);
	ScaleVector(offset, size);
	AddVectors(pos, offset, start);
	SubtractVectors(pos, offset, end);

	int color[4];
	nadeType.GetColor(color);

	TE_SetupBeamPoints(
		start,
		end,
		GetTrailMaterial(),
		0,
		0,
		0,
		lifetime,
		size,
		size,
		0,
		0.0,
		color,
		0);

	SendTempEnt(client, 0.0);
}

// Draw a ring to show where the grenade detonated.
void DrawRing(
	int client,
	const float pos[3],
	float size,
	float lifetime)
{
	int color[4] = { 255, 255, 255, 255 };

	TE_SetupBeamRingPoint(
		pos,
		size,
		size + 0.03125,
		GetTrailMaterial(),
		0,
		0,
		0,
		lifetime,
		sm_nadevision_width.FloatValue,
		0.0,
		color,
		0,
		0);
		
	SendTempEnt(client, 0.0);
}

// Draw a cross perpendicular to a direction to show grenade impacts.
void DrawCross(
	int client,
	const float pos[3],
	const float direction[3],
	const int color[4],
	float lifetime)
{
	float size = sm_nadevision_cross_size.FloatValue;
	if (size <= 0.0)
		return;

	float right[3], up[3];
	GetVectorVectors(direction, right, up);

	float tr[3], br[3], tl[3], bl[3];
	for (int i = 0; i < 3; i++)
	{
		tr[i] = pos[i] + (right[i] + up[i]) * size;
		br[i] = pos[i] + (right[i] - up[i]) * size;
		tl[i] = pos[i] + (-right[i] + up[i]) * size;
		bl[i] = pos[i] + (-right[i] - up[i]) * size;
	}

	DrawTrailSegment(client, tr, bl, color, lifetime, false);
	DrawTrailSegment(client, tl, br, color, lifetime, false);
}

// Draw a segment of the grenade trail.
void DrawTrailSegment(
	int client,
	const float start[3],
	const float end[3],
	const int color[4],
	float lifetime,
	bool dashed)
{
	// Don't draw first half of line if dashed.
	float newStart[3];
	if (dashed)
	{
		AddVectors(start, end, newStart);
		ScaleVector(newStart, 0.5);
	}
	else
	{
		newStart = start;
	}

	TE_SetupBeamPoints(
		newStart,
		end,
		GetTrailMaterial(),
		0,
		0,
		0,
		lifetime,
		sm_nadevision_width.FloatValue,
		sm_nadevision_width.FloatValue,
		0,
		0.0,
		color,
		0);

	SendTempEnt(client, 0.0);
}

// Returns whether a point is within the specified distance of the ground and
// moves it to there if so.
bool MoveToGround(float pos[3], float distance)
{
	float end[3];
	end[0] = pos[0];
	end[1] = pos[1];
	end[2] = pos[2] - distance;
	Handle trace = TR_TraceRayFilterEx(pos, end, MASK_SOLID, RayType_EndPoint, TraceFilter);
	bool result = TR_DidHit(trace);
	TR_GetEndPosition(pos, trace);
	trace.Close();

	return result;
}

// Collide and slide.
void SimplePlayerMove(float origin[3], float playerVel[3], bool &ducking, bool wasDucking)
{
	if (ducking && !wasDucking)
	{
		// Shrink the hull towards the center.
		origin[2] += (STAND_MAX[2] - CROUCH_MAX[2]) / 2;
	}

	if (!ducking && wasDucking)
	{
		// Try to expand the hull from the center.
		float end[3];
		end[0] = origin[0];
		end[1] = origin[1];
		end[2] = origin[2] - (STAND_MAX[2] - CROUCH_MAX[2]) / 2;

		Handle trace = TracePlayer(origin, end, true);
		if (TR_DidHit(trace))
		{
			ducking = true;
			trace.Close();
		}
		else
		{
			trace.Close();

			// Test standing hull.
			trace = TracePlayer(end, end, false);

			if (TR_DidHit(trace))
				ducking = true;
			else
				origin = end;

			trace.Close();
		}
	}

	float timeSlice = 1.0;

	for(int i = 0; i < MAX_PLAYER_COLLISIONS; i++)
	{
		float delta[3], end[3];
		delta = playerVel;
		ScaleVector(delta, GetTickInterval() * timeSlice);
		AddVectors(origin, delta, end);

		// Test collision.
		Handle trace = TracePlayer(origin, end, ducking);
		TR_GetEndPosition(origin, trace);

		if (!TR_DidHit(trace))
		{
			trace.Close();
			break;
		}

		float normal[3];
		TR_GetPlaneNormal(trace, normal);

		// Update the timeslice for the next move.
		timeSlice *= 1 - TR_GetFraction(trace);

		trace.Close();

		// Clip velocity.
		float impulse = GetVectorDotProduct(playerVel, normal);
		ScaleVector(normal, impulse);
		SubtractVectors(playerVel, normal, playerVel);
	}
}

// Get the eye position and velocity on the tick of release for a jump throw.
void ApplyJumpThrow(int client, int buttons, float eyePos[3], float playerVel[3], int tickBase)
{
	float origin[3];
	int firstTick = 0;
	float gravity = sv_gravity.FloatValue;
	float tickInterval = GetTickInterval();
	int moveTicks = RoundToFloor(NADE_THROW_TIME / tickInterval) + 2;
	bool stayDucking = (buttons & IN_DUCK) != 0;
	GetClientAbsOrigin(client, origin);

	if (!stayDucking)
	{
		// Check standing hull.
		Handle trace = TracePlayer(origin, origin, false);
		stayDucking = TR_DidHit(trace);
		trace.Close();
	}

	// Check if already throwing.
	if (tickBase == g_ReleaseTick[client])
	{
		return;
	}
	if (tickBase < g_ReleaseTick[client])
	{
		// Simulate from here.
		firstTick = moveTicks - (g_ReleaseTick[client] - tickBase);

		// Check if they actually jumped.
		if (firstTick > 0 && (GetEntityFlags(client) & FL_ONGROUND))
			return;
	}
	else
	{
		// Non-duck jumps are additive and get an extra half tick of gravity
		// from the StartGravity at the beginning of FullWalkMove.
		if (stayDucking)
			playerVel[2] = JUMP_VELOCITY;
		else
			playerVel[2] = JUMP_VELOCITY - gravity * tickInterval * 0.5;
	}

	bool duckJump = (buttons & IN_DUCK) && g_DuckJumpEnabled[client];
	bool wasDucking = stayDucking && !duckJump;

	// Simulate movement ticks.
	for (int i = firstTick; i < moveTicks; i++)
	{
		// Use average gravity.
		playerVel[2] -= gravity * tickInterval * 0.5;

		// Move and collision test the player.
		bool ducking = duckJump ? i == 0 : stayDucking;
		SimplePlayerMove(origin, playerVel, ducking, wasDucking);
		wasDucking = ducking;

		// Add remaining gravity.
		playerVel[2] -= gravity * tickInterval * 0.5;
	}

	eyePos[0] = origin[0];
	eyePos[1] = origin[1];
	if (wasDucking)
		eyePos[2] = origin[2] + CROUCH_VIEW_HEIGHT;
	else
		eyePos[2] = origin[2] + STAND_VIEW_HEIGHT;
}

// Given the player's eye position and angles, the player's velocity, and the grenade's
// m_flThrowStrength, calculates the position and velocity the grenade will spawn with.
void CalcGrenadeSpawn(int client, int weapon, int buttons, float nadePos[3], float nadeVel[3], int tickBase)
{
	float eyePos[3], eyeAngles[3], playerVel[3];
	float throwStrength = GetEntPropFloat(weapon, Prop_Send, "m_flThrowStrength");
	GetClientEyePosition(client, eyePos);
	NadeGetClientEyeAngles(client, eyeAngles);
	GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", playerVel);

	bool onGround = (GetEntityFlags(client) & FL_ONGROUND) != 0;

	if ((onGround && (buttons & IN_JUMP))
		|| (tickBase < g_ReleaseTick[client] && !onGround)
		|| (g_JumpThrowEnabled[client] && tickBase > g_ReleaseTick[client]))
	{
		ApplyJumpThrow(client, buttons, eyePos, playerVel, tickBase);
	}

	// Shift down by up to 12 units as throw strength approaches 0.
	nadePos[0] = eyePos[0];
	nadePos[1] = eyePos[1];
	nadePos[2] = eyePos[2] - (1.0 - throwStrength) * 12.0;

	// Adjust pitch upward by up to 10 degrees when looking forward and
	// down to 0 when looking up/down.
	eyeAngles[0] -= (90.0 - FloatAbs(eyeAngles[0])) * 10.0 / 90.0;

	float nadeDir[3];
	GetAngleVectors(eyeAngles, nadeDir, NULL_VECTOR, NULL_VECTOR);

	// Trace 22 units forward from the start position.
	float endPos[3];
	for (int i = 0; i < 3; i++)
		endPos[i] = nadePos[i] + nadeDir[i] * 22.0;

	Handle trace = TraceGrenade(nadePos, endPos);
	TR_GetEndPosition(nadePos, trace);
	trace.Close();

	// Bring the nade back 6 units from the trace end.
	// If the trace hit nothing, the grenade will spawn 16 units forward.
	for (int i = 0; i < 3; i++)
		nadePos[i] -= nadeDir[i] * 6.0;

	// Linearly scale speed from 30% to 100% based on throw strength.
	float nadeSpeed = 750.0 * 0.9 * ((0.7 * throwStrength) + 0.3);
	for (int i = 0; i < 3; i++)
		nadeVel[i] = nadeDir[i] * nadeSpeed;

	// Inherit 125% of the player's velocity.
	ScaleVector(playerVel, 1.25);
	AddVectors(nadeVel, playerVel, nadeVel);
}

// Simulate a grenade's movement in the given deltatime.
void TickGrenade(int client, float nadePos[3], float nadeVel[3], int &bounces, float bouncePos[3], float bounceNormal[3], float deltaTime)
{
	float nadeGravity = sv_gravity.FloatValue * 0.4;

	float endPos[3];
	endPos[0] = nadePos[0] + nadeVel[0] * deltaTime;
	endPos[1] = nadePos[1] + nadeVel[1] * deltaTime;
	// Average the effect of gravity for this tick.
	endPos[2] = nadePos[2] + (nadeVel[2] - nadeGravity * deltaTime * 0.5) * deltaTime;

	// Apply gravity.
	nadeVel[2] -= nadeGravity * deltaTime;

	Handle trace = TraceGrenade(nadePos, endPos);

	if (!TR_DidHit(trace))
	{
		// Complete move.
		nadePos = endPos;
		trace.Close();
		return;
	}

	BounceGrenade(client, trace, nadePos, nadeVel, deltaTime);

	// Zero velocity after 21 collisions.
	if (bounces++ > 20)
		nadeVel[0] = nadeVel[1] = nadeVel[2] = 0.0;

	TR_GetEndPosition(bouncePos, trace);
	TR_GetPlaneNormal(trace, bounceNormal);
	trace.Close();
}

// Simulate a grenade's movement after it impacts a surface.
void BounceGrenade(int client, Handle trace, float nadePos[3], float nadeVel[3], float deltaTime)
{
	// Get trace info.
	float traceNormal[3], endPos[3];
	float traceFraction = TR_GetFraction(trace);
	int traceEnt = TR_GetEntityIndex(trace);
	TR_GetPlaneNormal(trace, traceNormal);
	TR_GetEndPosition(endPos, trace);

	if (sm_nadevision_debug.BoolValue)
	{
		PrintToConsole(client, "--- Collision");
		PrintToConsole(client, "Entity     %i", traceEnt);
		PrintToConsole(client, "Start Pos  %f %f %f", nadePos[0], nadePos[1], nadePos[2]);
		PrintToConsole(client, "End Pos    %f %f %f", endPos[0], endPos[1], endPos[2]);
		PrintToConsole(client, "Normal     %f %f %f", traceNormal[0], traceNormal[1], traceNormal[2]);
		PrintToConsole(client, "Pre Vel    %f %f %f", nadeVel[0], nadeVel[1], nadeVel[2]);
		PrintToConsole(client, "Pre Spd    %f", GetVectorLength(nadeVel));
	}

	// Bounce with full elasticity first.
	float bounceImpulse = GetVectorDotProduct(traceNormal, nadeVel) * 2.0;

	for (int i = 0; i < 3; i++)
	{
		nadeVel[i] -= traceNormal[i] * bounceImpulse;

		if (FloatAbs(nadeVel[i]) < 0.1)
			nadeVel[i] = 0.0;
	}

	// Scale velocity by 0.45 (m_flElasticity of grenades).
	// Players add an additional 0.3 factor.
	if (traceEnt >= 1 && traceEnt <= MaxClients)
		ScaleVector(nadeVel, 0.3 * 0.45);
	else
		ScaleVector(nadeVel, 0.45);

	float speedSqr = GetVectorLength(nadeVel, true);
	bool slideOnWall = false;

	if (sm_nadevision_debug.BoolValue)
	{
		PrintToConsole(client, "Bounce Vel %f %f %f", nadeVel[0], nadeVel[1], nadeVel[2]);
		PrintToConsole(client, "Bounce Spd %f", SquareRoot(speedSqr));
	}

	if (traceNormal[2] <= PHYS_FLOOR_Z && (traceNormal[2] <= 0.1 || speedSqr >= 400.0))
	{
		// Continue moving and slide along the wall.
		slideOnWall = true;
	}
	else if (speedSqr > 96000.0)
	{
		// Lose speed if a floor is hit too hard.
		float nadeDir[3];
		NormalizeVector(nadeVel, nadeDir);

		float impactDot = GetVectorDotProduct(traceNormal, nadeDir);
		if (impactDot > 0.5)
			ScaleVector(nadeVel, 1.5 - impactDot);
	}

	if (slideOnWall || speedSqr > 400.0)
	{
		// Move the rest of the way for this tick.
		// Further collisions will simply stop the grenade's movement for the
		// remainder of the tick.
		for (int i = 0; i < 3; i++)
			endPos[i] += nadeVel[i] * (1.0 - traceFraction) * deltaTime;

		trace = TraceGrenade(nadePos, endPos);
		TR_GetEndPosition(nadePos, trace);
		trace.Close();
	}
	else
	{
		// Stop completely.
		nadePos = endPos;
		nadeVel[0] = nadeVel[1] = nadeVel[2] = 0.0;
	}

	if (sm_nadevision_debug.BoolValue)
	{
		PrintToConsole(client, "Final Vel  %f %f %f", nadeVel[0], nadeVel[1], nadeVel[2]);
		PrintToConsole(client, "Final Spd  %f", GetVectorLength(nadeVel));
	}
}

// Returns whether the client has a valid grenade primed, and gets the type if so.
bool InitGrenade(int client, int weapon, int tickBase, NadeTypeId &typeId)
{
	char classname[256];
	if (!GetEntityClassname(weapon, classname, 256))
		return false;

	for (int i = 0; ; i++)
	{
		if (StrEqual(classname, g_Nades[i].className))
		{
			typeId = view_as<NadeTypeId>(i);
			break;
		}

		if (i + 1 == NADE_Max)
			return false;
	}

	// Check if the grenade is primed or being thrown.
	return GetEntProp(weapon, Prop_Send, "m_bPinPulled") != 0 || tickBase <= g_ReleaseTick[client];
}
