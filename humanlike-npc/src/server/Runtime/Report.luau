--!strict
-- The reducers over what an NPC tick reports: an empty per-frame FrameStats, folding one tick's
-- Report into a frame, and summarizing a run's worth of reports (activities, locomotion states,
-- events, and the per-trip outcomes counted separately: arrived, abandon, changedMind,
-- goalInvalid, resets). Tests, the tell score and the debug adapter read these; nothing here
-- decides anything. It is not the Report shape itself (Runtime/Npc exports it, re-exported here)
-- and it does not run NPCs.
-- requires: Npc, Types

local Types = require(script.Parent.Parent.Types)
local Npc = require(script.Parent.Npc)

local Report = {}

export type NpcReport = Npc.Report

export type Summary = {
	activities: { [string]: number },
	events: { [string]: number },
	locomotion: { [string]: number },
	arrived: number,
	abandon: number,
	changedMind: number,
	goalInvalid: number,
	resets: number,
	ticks: number,
}

export type Entry = { id: string, report: NpcReport, now: number }

function Report.emptyFrame(): Types.FrameStats
	return {
		ticks = 0,
		brains = 0,
		pathMs = 0,
		tickMs = 0,
		spent = 0,
		pressure = 0,
		npcCount = 0,
		dropped = 0,
		wantSpawn = 0,
		pairWith = nil,
	}
end

-- Counts one tick into a frame: ticks, brains (a report whose brain ran), and, when the caller
-- keeps one, its event tally (`events[name] += 1` for every event string the report carries).
function Report.fold(frame: Types.FrameStats, report: NpcReport, events: { [string]: number }?)
	frame.ticks += 1
	if report.brainRan == true or (report.brainRan == nil and report.intent ~= "-") then
		frame.brains += 1
	end
	if events then
		for _, name in report.events do
			events[name] = (events[name] or 0) + 1
		end
	end
end

local function bump(counts: { [string]: number }, key: string)
	counts[key] = (counts[key] or 0) + 1
end

-- Tallies a run: activity names ("none" when idle between activities), locomotion states, every
-- event string, and the trip outcomes each counted from its own event so "abandon" (recovery gave
-- up), "changedMind" (the brain dropped the trip) and "goalInvalid" (the goal was no goal) never
-- share a counter.
function Report.summarize(reports: { Entry }): Summary
	local summary: Summary = {
		activities = {},
		events = {},
		locomotion = {},
		arrived = 0,
		abandon = 0,
		changedMind = 0,
		goalInvalid = 0,
		resets = 0,
		ticks = 0,
	}
	for _, entry in reports do
		local report = entry.report
		summary.ticks += 1
		bump(summary.activities, report.activity or "none")
		bump(summary.locomotion, report.locomotion)
		for _, name in report.events do
			bump(summary.events, name)
			if name == "arrived" then
				summary.arrived += 1
			elseif name == "abandon" then
				summary.abandon += 1
			elseif name == "changedMind" then
				summary.changedMind += 1
			elseif name == "goalInvalid" then
				summary.goalInvalid += 1
			elseif name == "reset" then
				summary.resets += 1
			end
		end
	end
	return summary
end

return Report
