#include <debugoverlays>
#include <sdkhooks>
#include <sdktools>
#include <sourcemod>

#define STOP_EPSILON 0.1

#define MAX_EDICTS 2048

int oldGroundEnt[MAX_EDICTS] = { -1, ... };

float frameTime;

ConVar sv_gravity;
ConVar sv_maxvelocity;
ConVar sv_player_fatal_fall_speed;
ConVar sv_player_max_safe_fall_speed;
ConVar sm_pred_frametime;

enum struct PredClient
{
	int      index;
	float    basevel[3];
	float    absvel[3];
	float    angvel[3];
	float    angles[3];
	float    pos[3];
	float    gravity;
	float    mins[3];
	float    maxs[3];
	MoveType moveType;
	float    elasticity;
	int      groundEnt;
}

public void OnPluginStart()
{
	sv_player_fatal_fall_speed = FindConVar("sv_player_fatal_fall_speed");
	sv_player_max_safe_fall_speed = FindConVar("sv_player_max_safe_fall_speed");
	sv_gravity     = FindConVar("sv_gravity");
	sv_maxvelocity = FindConVar("sv_maxvelocity");

	sm_pred_frametime = CreateConVar("sm_pred_frametime", "0.1", "The amount of time to predict ahead.");
	sm_pred_frametime.AddChangeHook(OnFrameTimeChanged);
	frameTime = sm_pred_frametime.FloatValue;
	
	//frameTime = GetTickInterval();

	RegConsoleCmd("sm_pred", Cmd_PredMe);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
		{
			OnClientPutInServer(i);
		}
	}
}

void OnFrameTimeChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	frameTime = sm_pred_frametime.FloatValue;
}

Action Cmd_PredMe(int client, int args)
{
	if (!client)
	{
		client = FindEntityByClassname(-1, "player");
	}

	int target = GetCmdArgInt(1);

	PredClient predClient;
	BuildPredClient(target, predClient);

	int times = GetCmdArgInt(2);
	if (!times)
	{
		times = 1;
	}

	char classname[64];
	GetEntityClassname(target, classname, sizeof(classname));
	//PrintToServer("Predicting %s %d times\n", classname, times);

	for (int i; i < times; i++)
	{
		DoPred(predClient);
		PrintToServer("{%.f %.f %.f} {%.f %.f %.f} %d", 
			predClient.absvel[0], predClient.absvel[1], predClient.absvel[2], 
			predClient.basevel[0], predClient.basevel[1], predClient.basevel[2],
			predClient.groundEnt);

		PrintToServer("Would take %f damage", GetFallDamage(-predClient.absvel[2]));
		
		if (predClient.groundEnt == 0) {
			break;
		}
	}
	return Plugin_Handled;
}

void BuildPredClient(int client, PredClient predClient)
{
	predClient.index = client;
	GetEntPropVector(client, Prop_Data, "m_vecBaseVelocity", predClient.basevel);
	GetEntPropVector(client, Prop_Data, "m_vecAbsVelocity", predClient.absvel);
	GetEntPropVector(client, Prop_Data, "m_vecAngVelocity", predClient.angvel);
	GetEntPropVector(client, Prop_Data, "m_angAbsRotation", predClient.angles);
	GetEntPropVector(client, Prop_Data, "m_vecAbsOrigin", predClient.pos);
	GetEntPropVector(client, Prop_Data, "m_vecMins", predClient.mins);
	GetEntPropVector(client, Prop_Data, "m_vecMaxs", predClient.maxs);
	predClient.gravity    = GetEntityGravity(client);
	predClient.moveType   = GetEntityMoveType(client);
	predClient.elasticity = GetEntPropFloat(client, Prop_Data, "m_flElasticity");
	predClient.groundEnt  = GetEntPropEnt(client, Prop_Data, "m_hGroundEntity");
}

float GetFallDamage(float speed)
{
    float maxSafeFallSpeed = sv_player_max_safe_fall_speed.FloatValue;
    return (speed - maxSafeFallSpeed) * 100.0 / (sv_player_fatal_fall_speed.FloatValue - maxSafeFallSpeed);
}

public void OnClientPutInServer(int client)
{
	SDKHook(client, SDKHook_PreThink, OnClientThink);
}

public void OnClientThink(int client)
{
	int groundEnt = GetEntPropEnt(client, Prop_Send, "m_hGroundEntity");

	if (groundEnt == -1 && oldGroundEnt[client] != -1)
	{
		OnClientBecomeAirbone(client);
	}

	oldGroundEnt[client] = groundEnt;
}

void OnClientBecomeAirbone(int client)
{
	//PrintToServer("%N became airbone", client);
	PredClient predClient;
	BuildPredClient(client, predClient);

	int times = 100;
	for (int i; i < times; i++)
	{
		DoPred(predClient);
	}
}

void DoPred(PredClient client)
{
	//PrintToServer("[%f] DoPred()", GetEngineTime());
	PhysicsCheckVelocity(client);

	float move[3];
	PhysicsAddGravityMove(client, move);

	SimulateAngles(client);

	Handle trace;
	PhysicsPushEntity(client, move, trace);

	PhysicsCheckVelocity(client);

	if (TR_DidHit(trace))  // we hit something mid air
	{
		//PrintToServer("[%f] Hit something mid air (%d)", GetEngineTime(), TR_GetEntityIndex(trace));
		PerformFlyCollisionResolution(client, trace, move);
	}
}

void PhysicsCheckVelocity(PredClient client)
{
	float origin[3];
	origin = client.pos;

	float vecAbsVelocity[3];
	vecAbsVelocity = client.absvel;

	bool bReset = false;
	for (int i = 0; i < 3; i++)
	{
		if (vecAbsVelocity[i] > sv_maxvelocity.FloatValue)
		{
			PrintToServer("Got a velocity too high");
			vecAbsVelocity[i] = sv_maxvelocity.FloatValue;
			bReset            = true;
		}
		else if (vecAbsVelocity[i] < -sv_maxvelocity.FloatValue)
		{
			PrintToServer("Got a velocity too low");
			vecAbsVelocity[i] = -sv_maxvelocity.FloatValue;
			bReset            = true;
		}
	}

	if (bReset)
	{
		client.pos    = origin;
		client.absvel = vecAbsVelocity;
	}
}

void PhysicsAddGravityMove(PredClient client, float move[3])
{
	//PrintToServer("PhysicsAddGravityMove");
	float vecAbsVelocity[3];
	vecAbsVelocity = client.absvel;

	move[0] = (vecAbsVelocity[0] + client.basevel[0]) * frameTime;
	move[1] = (vecAbsVelocity[1] + client.basevel[1]) * frameTime;

	if (client.groundEnt == 0)
	{
		move[2] = client.basevel[2] * frameTime;
		return;
	}

	// linear acceleration due to gravity
	float newZVelocity = vecAbsVelocity[2] - GetActualGravity(client) * frameTime;

	move[2] = ((vecAbsVelocity[2] + newZVelocity) / 2.0 + client.basevel[2]) * frameTime;

	float vecBaseVelocity[3];
	vecBaseVelocity    = client.basevel;
	vecBaseVelocity[2] = 0.0;
	client.basevel     = vecBaseVelocity;

	vecAbsVelocity[2] = newZVelocity;
	client.absvel     = vecAbsVelocity;

	// Bound velocity
	PhysicsCheckVelocity(client);
}

void SimulateAngles(PredClient client)
{
	float angles[3];
	VectorMA(client.angles, frameTime, client.angvel, angles);
	client.angles = angles;
}

float GetActualGravity(PredClient client)
{
	float ent_gravity = client.gravity;
	if (ent_gravity == 0.0)
	{
		ent_gravity = 1.0;
	}

	return ent_gravity * sv_gravity.FloatValue;
}

void PhysicsPushEntity(PredClient client, float push[3], Handle& trace)
{
	PhysicsCheckSweep(client, client.pos, push, trace);

	if (TR_GetFraction(trace))
	{
		TR_GetEndPosition(client.pos, trace);
	}
}

void PhysicsCheckSweep(PredClient client, float vecAbsStart[3], float vecAbsDelta[3], Handle& trace)
{
	//int mask = MASK_SOLID; fixme
	int mask = MASK_PLAYERSOLID;
	mask &= ~CONTENTS_MONSTER;

	float vecAbsEnd[3];
	AddVectors(vecAbsStart, vecAbsDelta, vecAbsEnd);

	UTIL_TraceEntity(client, vecAbsStart, vecAbsEnd, mask, trace);
}

void UTIL_TraceEntity(PredClient client, float vecAbsStart[3], float vecAbsEnd[3], int mask, Handle& trace)
{
	trace = TR_TraceHullFilterEx(vecAbsStart, vecAbsEnd, client.mins, client.maxs, mask, TR_IgnoreSelf, client.index);
	DrawSweptBox(vecAbsStart, vecAbsEnd, client.mins, client.maxs, NULL_VECTOR);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (strcmp(classname, "grenade_projectile") == 0)
	{
		SDKHook(entity, SDKHook_Spawn, OnGrenadeSpawn);
	}
}

public void OnGrenadeSpawn(int grenade)
{
	PredClient predClient;
	BuildPredClient(grenade, predClient);
	int times = 100;
	for (int i; i < times; i++)
	{
		DoPred(predClient);
	}
}

bool TR_IgnoreSelf(int entity, int contentsMask, int self)
{
	return entity != self;
}

void PerformFlyCollisionResolution(PredClient client, Handle& trace, float move[3])
{
	if (client.moveType == MOVETYPE_FLYGRAVITY)
	{
		ResolveFlyCollisionBounce(client, trace, move, 0.0);
	}
	else {
		ResolveFlyCollisionSlide(client, trace, move);
	}
}

void ResolveFlyCollisionSlide(PredClient client, Handle& trace, float vecVelocity[3])
{
	//PrintToServer("ResolveFlyCollisionSlide");
	// Get the impact surface's friction.

	float flSurfaceFriction;
	// physprops->GetPhysicsProperties( trace.surface.surfaceProps, NULL, NULL, &flSurfaceFriction, NULL );
	flSurfaceFriction = 0.8;  // fixme

	// A backoff of 1.0 is a slide.

	float normal[3];
	TR_GetPlaneNormal(trace, normal);

	float flBackOff = 1.0;
	float vecAbsVelocity[3];
	PhysicsClipVelocity(client.absvel, normal, vecAbsVelocity, flBackOff);

	// fix me, check this, else should prolly return, etc
	if (normal[0] == 1.0 || normal[0] == -1.0 || normal[1] == 1.0 || normal[1] == -1.0) 
	{
		client.absvel = vecAbsVelocity;
		return;
	}
	else
	{
		if (normal[2] > 0.7) {
			client.absvel = {0.0, 0.0, 0.0};
			return;
		}
		else
		{
			client.absvel = vecAbsVelocity;
			return;
		}
	}

	// Wtf does any of this do? Let's comment it out and find out!
	
	// AddVectors(vecAbsVelocity, client.basevel, vecVelocity);
	// float flSpeedSqr = GetVectorDotProduct(vecVelocity, vecVelocity);

	// // Verify that we have an entity.
	// int pEntity = TR_GetEntityIndex(trace);
	// if (pEntity == -1)
	// {
	// 	ThrowError("No entity in trace");
	// }

	// // Are we on the ground?
	// if (vecVelocity[2] < (GetActualGravity(client) * frameTime))
	// {
	// 	vecAbsVelocity[2] = 0.0;

	// 	// Recompute speedsqr based on the new absvel
	// 	AddVectors(vecAbsVelocity, client.basevel, vecVelocity);
	// 	flSpeedSqr = GetVectorDotProduct(vecVelocity, vecVelocity);
	// }
	// client.absvel = vecAbsVelocity;

	// if (flSpeedSqr < (30 * 30))
	// {
	// 	if (IsEntityStandable(pEntity))
	// 	{
	// 		client.groundEnt = pEntity;
	// 	}

	// 	// Reset velocities.
	// 	client.absvel = { 0.0, 0.0, 0.0 };
	// 	client.angvel = { 0.0, 0.0, 0.0 };
	// }
	// else
	// {
	// 	float traceFraction = TR_GetFraction(trace);
	// 	AddVectors(vecAbsVelocity, client.basevel, vecAbsVelocity);
	// 	vecAbsVelocity[0] *= (1.0 - traceFraction) * frameTime * flSurfaceFriction;
	// 	vecAbsVelocity[1] *= (1.0 - traceFraction) * frameTime * flSurfaceFriction;
	// 	vecAbsVelocity[2] *= (1.0 - traceFraction) * frameTime * flSurfaceFriction;
	// 	PhysicsPushEntity(client, vecAbsVelocity, trace);
	// }
}

bool IsEntityStandable(int pEntity)
{
	if (pEntity == 0)
	{
		return true;
	}
	return false;
}

int PhysicsClipVelocity(float _in[3], float normal[3], float out[3], float overbounce)
{
	float backoff;
	float change;
	float angle;
	int   i, blocked;

	blocked = 0;

	angle = normal[2];

	if (angle > 0)
	{
		blocked |= 1;  // floor
	}
	if (!angle)
	{
		blocked |= 2;  // step
	}

	backoff = GetVectorDotProduct(_in, normal) * overbounce;

	for (i = 0; i < 3; i++)
	{
		change = normal[i] * backoff;
		out[i] = _in[i] - change;
		if (out[i] > -STOP_EPSILON && out[i] < STOP_EPSILON)
		{
			out[i] = 0.0;
		}
	}

	return blocked;
}

void ResolveFlyCollisionBounce(PredClient client, Handle& trace, float vecVelocity[3], float flMinTotalElasticity)
{
	// Get the impact surface's elasticity.
	float flSurfaceElasticity;
	// physprops->GetPhysicsProperties( trace.surface.surfaceProps, NULL, NULL, NULL, &flSurfaceElasticity );
	flSurfaceElasticity = 0.3;

	float flTotalElasticity = client.elasticity * flSurfaceElasticity;
	if (flMinTotalElasticity > 0.9)
	{
		flMinTotalElasticity = 0.9;
	}

	flTotalElasticity = clamp(flTotalElasticity, flMinTotalElasticity, 0.9);

	// NOTE: A backoff of 2.0f is a reflection

	float normal[3];
	TR_GetPlaneNormal(trace, normal);

	float vecAbsVelocity[3];
	PhysicsClipVelocity(client.absvel, normal, vecAbsVelocity, 2.0);
	vecAbsVelocity[0] *= flTotalElasticity;
	vecAbsVelocity[1] *= flTotalElasticity;
	vecAbsVelocity[2] *= flTotalElasticity;

	// Get the total velocity (player + conveyors, etc.)
	AddVectors(vecAbsVelocity, client.basevel, vecVelocity);
	float flSpeedSqr = GetVectorDotProduct(vecVelocity, vecVelocity);

	// Stop if on ground.
	if (normal[2] > 0.7)  // Floor
	{
		// Verify that we have an entity.
		int pEntity = TR_GetEntityIndex(trace);
		if (pEntity == -1)
		{
			ThrowError("ASSERT pEntity");
		}

		// Are we on the ground?
		if (vecVelocity[2] < (GetActualGravity(client) * frameTime))
		{
			vecAbsVelocity[2] = 0.0;

			// Recompute speedsqr based on the new absvel
			AddVectors(vecAbsVelocity, client.basevel, vecVelocity);
			flSpeedSqr = GetVectorDotProduct(vecVelocity, vecVelocity);
		}

		client.absvel = vecAbsVelocity;

		if (flSpeedSqr < (30 * 30))
		{
			client.groundEnt = pEntity;

			// Reset velocities.
			client.absvel = { 0.0, 0.0, 0.0 };
			client.angvel = { 0.0, 0.0, 0.0 };
		}
		else
		{
			float vecDelta[3];
			SubtractVectors(client.basevel, vecAbsVelocity, vecDelta);

			float vecBaseDir[3];
			NormalizeVector(client.basevel, vecBaseDir);

			float flScale = GetVectorDotProduct(vecDelta, vecBaseDir);

			float traceFraction = TR_GetFraction(trace);

			vecVelocity = vecAbsVelocity;
			ScaleVector(vecVelocity, (1.0 - traceFraction) * frameTime);

			float scaledBaseVel[3];
			scaledBaseVel = client.basevel;
			ScaleVector(scaledBaseVel, flScale);

			VectorMA(vecVelocity, (1.0 - traceFraction) * frameTime, scaledBaseVel, vecVelocity);
			PhysicsPushEntity(client, vecVelocity, trace);
		}
	}
	else
	{
		// If we get *too* slow, we'll stick without ever coming to rest because
		// we'll get pushed down by gravity faster than we can escape from the wall.
		if (flSpeedSqr < (30 * 30))
		{
			// Reset velocities.
			client.absvel = { 0.0, 0.0, 0.0 };
			client.angvel = { 0.0, 0.0, 0.0 };
		}
		else
		{
			client.absvel = vecAbsVelocity;
		}
	}
}

void VectorMA(float start[3], float scale, float direction[3], float dest[3])
{
	dest[0] = start[0] + scale * direction[0];
	dest[1] = start[1] + scale * direction[1];
	dest[2] = start[2] + scale * direction[2];
}

float clamp(float d, float min, float max)
{
	float t = d < min ? min : d;
	return t > max ? max : t;
}

float FlPlayerFallDamage(float totalSpeed)
{
	float excessVel = totalSpeed - sv_player_max_safe_fall_speed.FloatValue;
	return excessVel * 100.0 / (sv_player_fatal_fall_speed.FloatValue - sv_player_max_safe_fall_speed.FloatValue);
}