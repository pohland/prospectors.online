// Author: Ivan Kazmenko (gassa@mail.ru)
module maps;
import std.algorithm;
import std.ascii;
import std.conv;
import std.datetime;
import std.digest.md;
import std.format;
import std.json;
import std.math;
import std.range;
import std.stdio;
import std.string;
import std.traits;
import std.typecons;

import prospectorsc_abi;
import transaction;

immutable int colorThreshold = 0x80;

auto parseBinary (T) (ref ubyte [] buffer)
{
	static if (is (Unqual !(T) == E [], E))
	{
		size_t len; // for sizes > 127, should use VarInt32 here
		len = parseBinary !(byte) (buffer);
		E [] res;
		res.reserve (len);
		foreach (i; 0..len)
		{
			res ~= parseBinary !(E) (buffer);
		}
		return res;
	}
	else static if (is (T == struct))
	{
		T res;
		alias fieldNames = FieldNameTuple !(T);
		alias fieldTypes = FieldTypeTuple !(T);
		static foreach (i; 0..fieldNames.length)
		{
			mixin ("res." ~ fieldNames[i]) =
			    parseBinary !(fieldTypes[i]) (buffer);
		}
		return res;
	}
	else
	{
		enum len = T.sizeof;
		T res = *(cast (T *) (buffer.ptr));
		buffer = buffer[len..$];
		return res;
	}
}

alias Coord = Tuple !(int, q{row}, int, q{col});

auto toCoord (long id)
{
	return Coord (cast (short) (id & 0xFFFF), cast (short) (id >> 16));
}

string classString (string value)
{
	if (value.front == 'c')
	{
		return "c";
	}
	if (value.back == 'x')
	{
		return "x";
	}
	if (value == "?")
	{
		return "q";
	}
	return value;
}

string valueString (string value)
{
	if (value.back == 'x')
	{
		value.popBack ();
	}
	if (value == "c")
	{
		return "&nbsp;";
	}
	if (value == "z")
	{
		return "&nbsp;";
	}
	return value;
}

bool canImprove (string a, string b)
{
	if (!a.empty && a.back == 'x')
	{
		a.popBack ();
	}
	if (!b.empty && b.back == 'x')
	{
		b.popBack ();
	}
	auto na = a.all !(isDigit);
	auto nb = b.all !(isDigit);
	auto va = a.empty ? -4 : (a[0] == 'z') ? -2 : (a[0] == '?') ? -1 :
	    na ? a.to !(int) : -3;
	auto vb = b.empty ? -4 : (b[0] == 'z') ? -2 : (b[0] == '?') ? -1 :
	    nb ? b.to !(int) : -3;
	return va < vb;
}

int toColorHash (string name)
{
	auto d = md5Of (name);
	int color;
	foreach (value; d[].retro.take (3))
	{
		color = (color << 8) | (0x70 + (value & 0x7F));
	}
	return color;
}

string toCommaNumber (real value, bool doStrip)
{
	string res = format ("%.3f", value);
	auto pointPos = res.countUntil ('.');
	if (doStrip)
	{
		while (res.back == '0')
		{
			res.popBack ();
		}
		if (res.back == '.')
		{
			res.popBack ();
		}
	}
	if (pointPos >= 4)
	{
		res = res[0..pointPos - 3] ~ ',' ~ res[pointPos - 3..$];
	}
	if (pointPos >= 7)
	{
		res = res[0..pointPos - 6] ~ ',' ~ res[pointPos - 6..$];
	}
	if (pointPos >= 10)
	{
		res = res[0..pointPos - 9] ~ ',' ~ res[pointPos - 9..$];
	}
	return res;
}

string toAmountString (long value, bool isGold = false, byte doStrip = 1)
{
	if (value == -1)
	{
		return "?";
	}
	if (doStrip > 1)
	{
		if (value >= 10_000)
		{
			value = (value / 1000) * 1000;
		}
	}
	if (isGold)
	{
		if (doStrip > 1 && value % 1000 == 0)
		{
			return toCommaNumber (value / 1000 * 1E+0L,
			    true) ~ "K";
		}
		else
		{
			return toCommaNumber (value * 1E+0L, true);
		}
	}
	else
	{
		return toCommaNumber (value * 1E-3L,
		    !!doStrip || isGold) ~ " kg";
	}
}

int [] toColorArray (string code)
{
	return code.drop (1).chunks (2).map !(x => to !(int) (x, 16)).array;
}

int [] mixColor (T) (const int [] a, const int [] b, T lo, T me, T hi)
{
	return zip (a, b).map !(v => ((v[0] * (hi - me) + v[1] * (me - lo)) /
	    (hi - lo)).to !(int)).array;
}

int toColorInt (const int [] c)
{
	int res = 0;
	foreach (ref e; c)
	{
		res = (res << 8) | e;
	}
	return res;
}

struct BuildingPlan
{
	long id;
	string name;
	string sign;
	int [] loColor;
	int [] hiColor;

	this (string cur)
	{
		auto t = cur.split ("\t").map !(strip).array;
		id = t[0].to !(int);
		name = t[1];
		sign = t[2];
		loColor = toColorArray (t[3]);
		hiColor = toColorArray (t[4]);
	}
}

int row (const ref locElement loc)
{
	return cast (short) (loc.id >> 16);
}

int col (const ref locElement loc)
{
	return cast (short) (loc.id & 0xFFFF);
}

int main (string [] args)
{
	immutable int buildStepLength =
	    (args.length > 1 && args[1] == "testnet") ? 1500 : 15000;
	immutable int buildSteps = 3;

	int rentPrice = -1;

	{
		auto statJSON = File ("stat.binary", "rb")
		    .byLine.joiner.parseJSON;
		foreach (ref row; statJSON["rows"].array)
		{
			auto hex = row["hex"].str.chunks (2).map !(value =>
			    to !(ubyte) (value, 16)).array;
			auto curStat = parseBinary !(statElement) (hex);
			if (!hex.empty)
			{
				assert (false);
			}
			rentPrice = curStat.rent_price.to !(int) * 30;
		}
	}

	locElement [Coord] locations;

	{
		auto locJSON = File ("loc.binary", "rb")
		    .byLine.joiner.parseJSON;
		foreach (ref row; locJSON["rows"].array)
		{
			auto id = row["key"].str.to !(long);
			auto coord = toCoord (id);
			auto hex = row["hex"].str.chunks (2).map !(value =>
			    to !(ubyte) (value, 16)).array;
			locations[coord] = parseBinary !(locElement) (hex);
			static immutable int [] emptyAlt = [0, 0, 0];
			if (!hex.empty && !hex.equal (emptyAlt))
			{
				assert (false);
			}
		}
	}

	int totalPlots = locations.length.to !(int);

	int minRow = int.max;
	int maxRow = int.min;
	int minCol = int.max;
	int maxCol = int.min;
	foreach (ref cur; locations)
	{
		minRow = min (minRow, cur.row);
		maxRow = max (maxRow, cur.row);
		minCol = min (minCol, cur.col);
		maxCol = max (maxCol, cur.col);
	}

	workerElement [] [string] workersByOwner;
	int [Coord] workerNum;

	{
		auto workerJSON = File ("worker.binary", "rb")
		    .byLine.joiner.parseJSON;
		foreach (ref row; workerJSON["rows"].array)
		{
			auto hex = row["hex"].str.chunks (2).map !(value =>
			    to !(ubyte) (value, 16)).array;
			auto curWorker = parseBinary !(workerElement) (hex);
			if (!hex.empty)
			{
				assert (false);
			}
			auto locId = curWorker.loc_id;
			auto pos = toCoord (locId);
			workerNum[pos] += 1;
			auto owner = curWorker.owner.text;
			workersByOwner[owner] ~= curWorker;
		}
	}

	auto nowTime = Clock.currTime (UTC ());
	auto nowString = nowTime.toSimpleString[0..20];
	auto nowUnix = nowTime.toUnixTime ();

	auctionElement [Coord] auctions;

	{
		auto auctionJSON = File ("auction.binary", "rb")
		    .byLine.joiner.parseJSON;
		foreach (ref row; auctionJSON["rows"].array)
		{
			auto hex = row["hex"].str.chunks (2).map !(value =>
			    to !(ubyte) (value, 16)).array;
			auto curAuction = parseBinary !(auctionElement) (hex);
			if (!hex.empty)
			{
				assert (false);
			}
			auto locId = curAuction.loc_id;
			auto pos = toCoord (locId);
			if (curAuction.target.text != "" ||
			    curAuction.end_time < nowUnix ||
			    (curAuction.type != 0 && curAuction.type != 2))
			{
				continue;
			}
			auctions[pos] = curAuction;
		}
	}

	auto buildings = BuildingPlan.init ~ File ("../buildings.txt", "rt")
	    .byLineCopy.map !(line => BuildingPlan (line)).array;

	int calcBuildingDone () (auto ref Coord pos)
	{
	}

	int [Coord] buildingDone;

	foreach (pos, ref cur; locations)
	{
		auto buildId = cur.building.build_id;
		auto buildStep = cur.building.build_step;
		auto buildAmount = cur.building.build_amount;
		auto buildReadyTime = cur.building.ready_time;
		auto buildJobOwners = cur.jobs
		    .filter !(line => line.job_type == 4)
		    .map !(line => line.owner.text).array;
		sort (buildJobOwners);
		buildJobOwners = buildJobOwners.uniq.array;
		long [] buildJobStartTime;
		long [] buildJobReadyTime;
		foreach (curOwner; buildJobOwners)
		{
			foreach (worker; workersByOwner[curOwner])
			{
				if (worker.job.job_type == 4 &&
				    worker.job.loc_id.toCoord == pos)
				{
					buildJobStartTime ~=
					    worker.job.loc_time;
					buildJobReadyTime ~=
					    worker.job.ready_time;
				}
			}
		}

		auto doneMinutes = buildAmount;
		doneMinutes += buildStepLength * buildStep;
		auto doneSeconds = doneMinutes * 60;
		foreach (j; 0..buildJobStartTime.length)
		{
			auto start = buildJobStartTime[j];
			auto ready = buildJobReadyTime[j];
			start = max (start, nowUnix);
			auto duration = ready - start;
			duration = max (0, duration);
			doneSeconds -= duration;
		}
		buildingDone[pos] = doneSeconds / 60;
	}

	string toCoordString (Coord pos)
	{
		string numString (int value)
		{
			immutable int base = 10;
			string res;
			if (value < 0)
			{
				res ~= "-";
				value = -value;
			}
			res ~= cast (char) (value / base + '0');
			res ~= cast (char) (value % base + '0');
			return res;
		}

		// as in the game: first column, then row
		auto res = numString (pos.col) ~ "/" ~ numString (pos.row);
		if (locations[pos].name != "")
		{
			res ~= ", " ~ locations[pos].name;
		}
		return res;
	}

	int rentDaysLeft () (auto ref Coord pos)
	{
		auto rentTime = locations[pos].rent_time.to !(long);
		auto secLeft = rentTime - nowUnix;
		auto realDaysLeft = floor (secLeft / (1.0L * 60 * 60 * 24));
		return realDaysLeft.to !(int);
	}

	foreach (row; minRow..maxRow + 1)
	{
		foreach (col; minCol..maxCol + 1)
		{
			auto pos = Coord (row, col);
			if (pos !in locations)
			{
				locations[pos] = locElement ();
				locations[pos].name = "(does not exist)";
			}
		}
	}

	foreach (row; minRow..maxRow + 1)
	{
		foreach (col; minCol..maxCol + 1)
		{
			auto pos = Coord (row, col);
			if (pos !in locations)
			{
				assert (false);
			}
			auto intDaysLeft = rentDaysLeft (pos);
			if (intDaysLeft == -8 && pos !in auctions)
			{
				auctions[pos] = auctionElement.init;
				auctions[pos].price = rentPrice;
				auctions[pos].bid_user = Name ("");
				auctions[pos].end_time =
				    locations[pos].rent_time +
				    60 * 60 * 24 * 8;
			}
		}
	}

	void writeHtmlHeader (ref File file, string title)
	{
		file.writeln (`<!DOCTYPE html>`);
		file.writeln (`<html xmlns="http://www.w3.org/1999/xhtml">`);
		file.writeln (`<meta http-equiv="content-type" ` ~
		    `content="text/html; charset=UTF-8">`);
		file.writeln (`<head>`);
		file.writefln (`<title>%s map</title>`, title);
		file.writeln (`<link rel="stylesheet" href="map.css" ` ~
		    `type="text/css">`);
		file.writeln (`</head>`);
		file.writeln (`<body>`);
		file.writeln (`<table class="map">`);
		file.writeln (`<tbody>`);
	}

	void writeCoordRow (ref File file)
	{
		file.writeln (`<tr>`);
		file.writeln (`<td class="coord">&nbsp;</td>`);
		foreach (col; minCol..maxCol + 1)
		{
			file.writeln (`<td class="coord">`, col, `</td>`);
		}
		file.writeln (`<td class="coord">&nbsp;</td>`);
		file.writeln (`</tr>`);
	}

	alias ResTemplate = Tuple !(string, q{name},
	    int delegate (Coord), q{fun}, int, q{divisor});

	string makeValue () (auto ref ResTemplate resource, Coord pos,
	    bool maskOwner = true)
	{
		auto value = resource.fun (pos);
		string res = value.text;
		if (pos == Coord (0, 0))
		{
			res = "c";
		}
		else if (res == "-1")
		{
			res = "?";
		}
		else if (value > 0)
		{
			res = text (value / resource.divisor);
		}
		else if (value == 0)
		{
			res = "z";
		}
		else
		{
			assert (false);
		}
		if (maskOwner && locations[pos].owner.text != "")
		{
			res ~= "x";
		}
		return res;
	}

	int [string] resourceLimit;
	resourceLimit["gold"]   = 32_000_000;
	resourceLimit["wood"]   = 19_000_000;
	resourceLimit["stone"]  = 22_000_000;
	resourceLimit["coal"]   = 16_000_000;
	resourceLimit["clay"]   = 16_000_000;
	resourceLimit["ore"]    = 32_000_000;
	resourceLimit["coffee"] =    300_000;

	ResTemplate [] resTemplate;
	resTemplate ~= ResTemplate ("gold",
	    pos => locations[pos].gold,   10 ^^ 6);
	resTemplate ~= ResTemplate ("wood",
	    pos => locations[pos].wood,   10 ^^ 6);
	resTemplate ~= ResTemplate ("stone",
	    pos => locations[pos].stone,  10 ^^ 6);
	resTemplate ~= ResTemplate ("coal",
	    pos => locations[pos].coal,   10 ^^ 6);
	resTemplate ~= ResTemplate ("clay",
	    pos => locations[pos].clay,   10 ^^ 6);
	resTemplate ~= ResTemplate ("ore",
	    pos => locations[pos].ore,    10 ^^ 6);
	resTemplate ~= ResTemplate ("coffee",
	    pos => locations[pos].coffee, 10 ^^ 4);
	resTemplate ~= ResTemplate ("worker",
	    pos => pos in workerNum ? workerNum[pos] : 0, 10 ^^ 0);

	int totalResources = resTemplate.length.to !(int) - 1;

	void doHtml (ResTemplate [] resources)
	{
		auto title = format ("%-(%s_%)", resources.map !(t => t.name));
		if (resources.length == totalResources)
		{
			title = "combined";
		}

		auto file = File (title ~ ".html", "wt");
		writeHtmlHeader (file, title);
		writeCoordRow (file);
		long [string] [string] quantity;
		int [string] [string] richPlots;
		Coord [] [string] [string] plotsByOwner;
		int [string] totalRichPlots;
		int [string] totalUnknownPlots;
		long [string] totalQuantity;
		foreach (name; resources.map !(t => t.name))
		{
			quantity[""][name] = 0;
			richPlots[""][name] = 0;
			plotsByOwner[""][name] = null;
			totalRichPlots[name] = 0;
			totalUnknownPlots[name] = 0;
			totalQuantity[name] = 0;
		}

		foreach (row; minRow..maxRow + 1)
		{
			file.writeln (`<tr>`);
			file.writeln (`<td class="coord">`, row, `</td>`);
			foreach (col; minCol..maxCol + 1)
			{
				auto pos = Coord (row, col);
				if (pos !in locations)
				{
					assert (false);
				}
				auto owner = locations[pos].owner.text;
				auto hoverText = toCoordString (pos);
				string bestName;
				string bestValue;
				foreach (ref resource; resources)
				{
					auto name = resource.name;
					auto fun = resource.fun;
					auto divisor = resource.divisor;
					auto value = makeValue (resource, pos);
					auto curQuantity = max (0, fun (pos));
					if (curQuantity > 0)
					{
						quantity[owner][name] +=
						    curQuantity;
						totalQuantity[name] +=
						    curQuantity;
						plotsByOwner[owner][name] ~=
						    pos;
					}
					auto isRichPlot = (fun (pos) * 2 >
					    resourceLimit[name]);
					richPlots[owner][name] += isRichPlot;
					totalRichPlots[name] += isRichPlot;
					totalUnknownPlots[name] +=
					    (fun (pos) == -1);
					hoverText ~= `&#10;` ~ name ~ `: ` ~
					    fun (pos).toAmountString
					    (name == "gold");
					if (canImprove (bestValue, value))
					{
						bestName = name;
						bestValue = value;
					}
				}
				if (owner != "")
				{
					hoverText ~= `&#10;owner: ` ~ owner;
				}
				file.writefln (`<td class="plot %s-%s" ` ~
				    `title="%s">%s</td>`,
				    bestName, classString (bestValue),
				    hoverText, valueString (bestValue));
			}
			file.writeln (`<td class="coord">`, row, `</td>`);
			file.writeln (`</tr>`);
		}
		writeCoordRow (file);
		file.writeln (`</tbody>`);
		file.writeln (`</table>`);
		file.writefln (`<p>Generated on %s (UTC).</p>`, nowString);
		file.writefln (`<p>Tip: hover the mouse over a plot ` ~
		    `to see details.</p>`);

		if (resources.length == 1)
		{
			auto name = resources.front.name;
			auto fun = resources.front.fun;
			bool showRich = (name != "wood" &&
			    name != "stone" &&
			    name != "coffee");

			auto plotOwners = quantity.byKey ().array;
			if (showRich)
			{
				plotOwners.schwartzSort !(owner =>
				    tuple (-richPlots[owner][name],
				    -quantity[owner][name], owner));
			}
			else
			{
				plotOwners.schwartzSort !(owner =>
				    tuple (-quantity[owner][name], owner));
			}
			plotOwners = plotOwners.until !(owner =>
			    owner != "" && quantity[owner][name] == 0).array;
			file.writefln (`<h2>Richest %s plot owners:</h2>`,
			    name);
			file.writeln (`<table border="1px" padding="2px">`);
			file.writeln (`<tbody>`);

			file.writeln (`<tr>`);
			file.writefln (`<th>#</th>`);
			file.writefln (`<th class="plot" ` ~
			    `width="16px">&nbsp;</th>`);
			file.writefln (`<th>Account</th>`);
			if (showRich)
			{
				file.writefln (`<th>Rich plots</th>`);
			}
			file.writefln (`<th>Total quantity</th>`);
			file.writefln (`<th>Best plots</th>`);
			file.writeln (`</tr>`);

			foreach (i, owner; plotOwners)
			{
				file.writeln (`<tr>`);
				file.writeln (`<td style="text-align:right">`,
				    (i + 1), `</td>`);
				auto backgroundColor = (owner == "") ?
				    0xEEEEEE : toColorHash (owner);
				file.writefln (`<td class="plot" ` ~
				    `width="16px" ` ~
				    `style="background-color:#%06X">` ~
				    `&nbsp;</td>`, backgroundColor);
				file.writeln (`<td style='font-family:` ~
				    `"Courier New", Courier, monospace'>`,
				    owner == "" ? "(free plots)" : owner,
				    `</td>`);
				if (showRich)
				{
					file.writeln (`<td style=` ~
					    `"text-align:right">`,
					    richPlots[owner][name], `</td>`);
				}
				file.writeln (`<td style="text-align:right">`,
				    toAmountString (quantity[owner][name],
				    name == "gold", false), `</td>`);
				auto curPlots = plotsByOwner[owner][name];
				auto plotsToShow = min (3, curPlots.length);
				curPlots.schwartzSort !(pos =>
				    tuple (-fun (pos), pos));
				file.writefln (`<td>%-(%s, %)%s</td>`,
				    curPlots[0..plotsToShow].map !(pos =>
				    format (`<span class="%s-%s">` ~
				    `%s (%s)</span>`, name,
				    classString (makeValue
				    (resources.front, pos, false)),
				    toCoordString (pos),
				    toAmountString (fun (pos),
				    name == "gold", 2))),
				    (plotsToShow < curPlots.length) ?
				    ", ..." : "");
				file.writeln (`</tr>`);
			}

			file.writeln (`<tr>`);
			file.writeln (`<td style="text-align:right">` ~
			    `&nbsp;</td>`);
			file.writefln (`<td class="plot" width="16px">` ~
			    `&nbsp;</td>`);
			file.writeln (`<td style="font-weight:bold">` ~
			    `Total</td>`);
			if (showRich)
			{
				file.writeln (`<td style="text-align:right">` ~
				    `&nbsp;</td>`);
			}
			file.writeln (`<td style="text-align:right">`,
			    toAmountString (totalQuantity[name],
			    name == "gold", false), `</td>`);
			file.writeln (`<td>&nbsp;</td>`);
			file.writeln (`</tr>`);

			if (showRich)
			{
				file.writeln (`<tr>`);
				file.writeln (`<td style="text-align:right">` ~
				    `&nbsp;</td>`);
				file.writeln (`<td class="plot" ` ~
				    `width="16px">&nbsp;</td>`);
				file.writeln (`<td style="font-weight:bold">` ~
				    `Rich plots</td>`);
				file.writeln (`<td style="text-align:right">` ~
				    `&nbsp;</td>`);
				file.writeln (`<td style="text-align:right">`,
				    totalRichPlots[name], `</td>`);
				file.writeln (`<td>&nbsp;</td>`);
				file.writeln (`</tr>`);

				file.writeln (`<tr>`);
				file.writeln (`<td style="text-align:right">` ~
				    `&nbsp;</td>`);
				file.writeln (`<td class="plot" ` ~
				    `width="16px">&nbsp;</td>`);
				file.writeln (`<td style="font-weight:bold">` ~
				    `Unknown</td>`);
				file.writeln (`<td style="text-align:right">` ~
				    `&nbsp;</td>`);
				file.writeln (`<td style="text-align:right">`,
				    totalUnknownPlots[name], `</td>`);
				file.writeln (`<td>&nbsp;</td>`);
				file.writeln (`</tr>`);
			}

			file.writeln (`</tbody>`);
			file.writeln (`</table>`);

			if (showRich)
			{
				file.writefln (`<p>A plot is rich ` ~
				    `if it contains more than %s %s.</p>`,
				    toAmountString (resourceLimit[name] / 2,
				    name == "gold"), name);
			}
		}
		file.writefln (`<p><a href="..">Back to main page</a></p>`);
		file.writeln (`</body>`);
		file.writeln (`</html>`);
	}

	void doHtmlWorker (ResTemplate [] resources)
	{
		if (resources.length != 1)
		{
			assert (false);
		}

		auto title = format ("%-(%s_%)", resources.map !(t => t.name));

		auto file = File (title ~ ".html", "wt");
		writeHtmlHeader (file, title);
		writeCoordRow (file);
		real midRow = 0.0;
		real midCol = 0.0;
		real midDen = 0.0;
		foreach (row; minRow..maxRow + 1)
		{
			file.writeln (`<tr>`);
			file.writeln (`<td class="coord">`, row, `</td>`);
			foreach (col; minCol..maxCol + 1)
			{
				auto pos = Coord (row, col);
				if (pos !in locations)
				{
					assert (false);
				}
				auto owner = locations[pos].owner.text;
				auto hoverText = toCoordString (pos);
				string bestName;
				string bestValue;
				foreach (ref resource; resources)
				{
					auto name = resource.name;
					auto fun = resource.fun;
					auto divisor = resource.divisor;
					auto value = min (fun (pos), 99).text;
					midRow += row * fun (pos);
					midCol += col * fun (pos);
					midDen += fun (pos);
					hoverText ~= `&#10;workers: ` ~
					    fun (pos).text;
					if (fun (pos) == 0)
					{
						value = "z";
					}
					if (canImprove (bestValue, value))
					{
						bestName = name;
						bestValue = value;
					}
				}
				if (owner != "")
				{
					hoverText ~= `&#10;owner: ` ~ owner;
				}
				file.writefln (`<td class="plot %s-%s" ` ~
				    `title="%s">%s</td>`,
				    bestName, classString (bestValue),
				    hoverText, valueString (bestValue));
			}
			file.writeln (`<td class="coord">`, row, `</td>`);
			file.writeln (`</tr>`);
		}
		writeCoordRow (file);
		file.writeln (`</tbody>`);
		file.writeln (`</table>`);
		file.writefln (`<p>Generated on %s (UTC).</p>`, nowString);
		file.writefln (`<p>Average worker position: ` ~
		    `%.2f/%.2f.</p>`, midCol / midDen, midRow / midDen);
		file.writefln (`<p>Tip: hover the mouse over a plot ` ~
		    `to see details.</p>`);
		file.writefln (`<p><a href="..">Back to main page</a></p>`);
		file.writeln (`</body>`);
		file.writeln (`</html>`);
	}

	enum RentMapType {simple, daysLeft, auction}

	void doHtmlRent (string name, RentMapType type)
	{
		auto title = name;

		auto file = File (title ~ ".html", "wt");
		writeHtmlHeader (file, title);
		writeCoordRow (file);

		int [string] numPlots;
		foreach (row; minRow..maxRow + 1)
		{
			file.writeln (`<tr>`);
			file.writeln (`<td class="coord">`, row, `</td>`);
			foreach (col; minCol..maxCol + 1)
			{
				auto pos = Coord (row, col);
				if (pos !in locations)
				{
					assert (false);
				}
				auto owner = locations[pos].owner.text;
				numPlots[owner] += 1;
				auto backgroundColor = (owner == "") ?
				    0xEEEEEE : toColorHash (owner);
				if (type == RentMapType.auction &&
				    owner != "" &&
				    pos !in auctions)
				{
					backgroundColor = 0xBBBBBB;
				}
				auto hoverText = toCoordString (pos);
				if (owner != "")
				{
					hoverText ~= `&#10;owner: ` ~ owner;
				}
				auto daysLeft = "&nbsp;";
				if (type != RentMapType.simple && owner != "")
				{
					auto rentTime =
					    locations[pos].rent_time;
					auto secLeft = rentTime - nowUnix;
					auto intDaysLeft = rentDaysLeft (pos);
					intDaysLeft = min (intDaysLeft, 99);
					intDaysLeft = max (intDaysLeft, -9);
					daysLeft = intDaysLeft.text;
					hoverText ~= `&#10;rent paid: ` ~
					    dur !(q{minutes}) (secLeft / 60)
					    .text;
				}
				file.writefln (`<td class="plot" ` ~
				    `style="background-color:#%06X" ` ~
				    `title="%s">%s</td>`,
				    backgroundColor, hoverText, daysLeft);
			}
			file.writeln (`<td class="coord">`, row, `</td>`);
			file.writeln (`</tr>`);
		}
		writeCoordRow (file);

		file.writeln (`</tbody>`);
		file.writeln (`</table>`);
		file.writefln (`<p>Generated on %s (UTC).</p>`, nowString);
		file.writefln (`<p>Tip: hover the mouse over a plot ` ~
		    `to see details.</p>`);

		if (type == RentMapType.simple)
		{
			auto plotsByNum = numPlots.byKeyValue ().array;
			plotsByNum.schwartzSort !(line =>
			    tuple (-line.value, line.key));
			file.writeln (`<h2>Owners by number of plots:</h2>`);
			file.writeln (`<table border="1px" padding="2px">`);
			file.writeln (`<tbody>`);

			file.writeln (`<tr>`);
			file.writefln (`<th>#</th>`);
			file.writefln (`<th class="plot" ` ~
			    `width="16px">&nbsp;</th>`);
			file.writefln (`<th>Account</th>`);
			file.writefln (`<th>Plots</th>`);
			file.writeln (`</tr>`);

			foreach (i, t; plotsByNum)
			{
				auto backgroundColor = (t.key == "") ?
				    0xEEEEEE : toColorHash (t.key);
				file.writeln (`<tr>`);
				file.writeln (`<td style="text-align:right">`,
				    (i + 1), `</td>`);
				file.writefln (`<td class="plot" ` ~
				    `width="16px" ` ~
				    `style="background-color:#%06X">` ~
				    `&nbsp;</td>`, backgroundColor);
				file.writeln (`<td style='font-family:` ~
				    `"Courier New", Courier, monospace'>`,
				    t.key == "" ? "(free plots)" : t.key,
				    `</td>`);
				file.writeln (`<td style="text-align:right">`,
				    t.value, `</td>`);
				file.writeln (`</tr>`);
			}
			file.writeln (`</tbody>`);
			file.writeln (`</table>`);
		}
		else if (type == RentMapType.daysLeft)
		{
			auto plotsBlocked = locations.byKeyValue ()
			    .filter !(line => line.value.owner.text != "" &&
			    rentDaysLeft (line.key) < 0).array;
			plotsBlocked.schwartzSort !(line =>
			    tuple (rentDaysLeft (line.key),
			    toCoordString (line.key)));
			file.writeln (`<h2>Blocked plots:</h2>`);
			file.writeln (`<p>Click on a column header ` ~
			    `to sort.</p>`);
			file.writeln (`<table id="blocked-list" ` ~
			    `border="1px" padding="2px">`);
			file.writeln (`<thead>`);
			file.writeln (`<tr>`);
			file.writefln (`<th>#</th>`);
			file.writefln (`<th class="plot" ` ~
			    `width="16px">&nbsp;</th>`);
			file.writefln (`<th>Plot</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-owner">Owner</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-rent">Rent days left</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-gold">Gold</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-wood">Wood</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-stone">Stone</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-coal">Coal</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-clay">Clay</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-ore">Ore</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-coffee">Coffee</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-building">Building</th>`);
			file.writeln (`</tr>`);
			file.writeln (`</thead>`);
			file.writeln (`<tbody>`);

			foreach (i, t; plotsBlocked)
			{
				auto backgroundColor =
				    (t.value.owner.text == "") ? 0xEEEEEE :
				    toColorHash (t.value.owner.text);
				file.writeln (`<tr>`);
				file.writeln (`<td style="text-align:right">`,
				    (i + 1), `</td>`);
				file.writefln (`<td class="plot" ` ~
				    `width="16px" ` ~
				    `style="background-color:#%06X">` ~
				    `&nbsp;</td>`, backgroundColor);
				file.writeln (`<td>`,
				    toCoordString (t.key), `</td>`);
				file.writeln (`<td style='font-family:` ~
				    `"Courier New", Courier, monospace'>`,
				    t.value.owner, `</td>`);
				auto rentLeft = rentDaysLeft (t.key);
				file.writeln (`<td style="text-align:right">`,
				    rentLeft, `</td>`);
				foreach (r; 0..totalResources)
				{
					file.writefln (`<td class="%s-%s" ` ~
					    `style="text-align:right">%s</td>`,
					    resTemplate[r].name, classString
					    (makeValue (resTemplate[r], t.key)
					    [0..$ - 1]),
					    toAmountString (resTemplate[r].fun
					    (t.key), resTemplate[r].name ==
					    "gold", false));
				}
				auto backgroundColorBuilding = 0xEEEEEE;
				auto buildingDetails = "&nbsp;";
				auto buildId = t.value.building.build_id;
				if (buildId != 0)
				{
					buildingDetails =
					    buildings[buildId].name;
					auto done = buildingDone[t.key];
					if (done != buildStepLength *
					    buildSteps)
					{
						buildingDetails ~= format
						    (`, %d%% built`,
						    done * 100L /
						    (buildStepLength *
						    buildSteps));
					}
					backgroundColorBuilding = mixColor
					    (buildings[buildId].loColor,
					    buildings[buildId].hiColor,
					    0, done, buildStepLength *
					    buildSteps).toColorInt;
				}
				string whiteFont;
				immutable int colorThreshold = 0x80;
				if (buildId != 0 &&
				    buildings[buildId].loColor.all !(c =>
				    c < colorThreshold))
				{
					whiteFont ~= `;color:#FFFFFF`;
					whiteFont ~= `;border-color:#000000`;
				}
				file.writefln (`<td style="text-align:left;` ~
				    `background-color:#%06X%s">%s</td>`,
				    backgroundColorBuilding, whiteFont,
				    buildingDetails);
				file.writeln (`</tr>`);
			}
			file.writeln (`</tbody>`);
			file.writeln (`</table>`);
			file.writeln (`<script src="blocked.js"></script>`);
		}
		else if (type == RentMapType.auction)
		{
			auto plotsAuction = locations.byKeyValue ().filter
			    !(line => line.key in auctions).array;
			plotsAuction.schwartzSort !(line =>
			    tuple (auctions[line.key].price,
			    auctions[line.key].end_time,
			    -line.value.rent_time));
			file.writeln (`<h2>Active auctions:</h2>`);
			file.writeln (`<p>Click on a column header ` ~
			    `to sort.</p>`);
			file.writeln (`<table id="auction-list" ` ~
			    `border="1px" padding="2px">`);
			file.writeln (`<thead>`);
			file.writeln (`<tr>`);
			file.writefln (`<th>#</th>`);
			file.writefln (`<th class="plot" ` ~
			    `width="16px">&nbsp;</th>`);
			file.writefln (`<th>Plot</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-owner">Owner</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-active">Active</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-price">Price</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-bidder">Bidder</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-rent">Rent days left</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-gold">Gold</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-wood">Wood</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-stone">Stone</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-coal">Coal</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-clay">Clay</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-ore">Ore</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-coffee">Coffee</th>`);
			file.writefln (`<th class="header" ` ~
			    `id="col-building">Building</th>`);
			file.writeln (`</tr>`);
			file.writeln (`</thead>`);
			file.writeln (`<tbody>`);

			foreach (i, t; plotsAuction)
			{
				auto backgroundColor =
				    (t.value.owner.text == "") ? 0xEEEEEE :
				    toColorHash (t.value.owner.text);
				file.writeln (`<tr>`);
				file.writeln (`<td style="text-align:right">`,
				    (i + 1), `</td>`);
				file.writefln (`<td class="plot" ` ~
				    `width="16px" ` ~
				    `style="background-color:#%06X">` ~
				    `&nbsp;</td>`, backgroundColor);
				file.writeln (`<td>`,
				    toCoordString (t.key), `</td>`);
				file.writeln (`<td style='font-family:` ~
				    `"Courier New", Courier, monospace'>`,
				    t.value.owner, `</td>`);
				auto minutesLeft =
				    auctions[t.key].end_time - nowUnix;
				minutesLeft /= 60;
				minutesLeft = max (0, minutesLeft);
				file.writefln (`<td ` ~
				    `style="text-align:center" ` ~
				    `style='font-family:` ~
				    `"Courier New", Courier, monospace'>` ~
				    `%02d:%02d</td>`,
				    minutesLeft / 60,
				    minutesLeft % 60);
				file.writefln (`<td ` ~
				    `style="text-align:right">%s</td>`,
				    toCommaNumber (auctions[t.key].price,
				    true));
				file.writeln (`<td style='font-family:` ~
				    `"Courier New", Courier, monospace'>`,
				    auctions[t.key].bid_user.text, `</td>`);
				auto rentLeft = rentDaysLeft (t.key);
				file.writeln (`<td style="text-align:right">`,
				    rentLeft, `</td>`);
				foreach (r; 0..totalResources)
				{
					file.writefln (`<td class="%s-%s" ` ~
					    `style="text-align:right">%s</td>`,
					    resTemplate[r].name, classString
					    (makeValue (resTemplate[r], t.key)
					    [0..$ - 1]),
					    toAmountString (resTemplate[r].fun
					    (t.key), resTemplate[r].name ==
					    "gold", false));
				}
				auto backgroundColorBuilding = 0xEEEEEE;
				auto buildingDetails = "&nbsp;";
				auto buildId = t.value.building.build_id;
				if (buildId != 0)
				{
					buildingDetails =
					    buildings[buildId].name;
					auto done = buildingDone[t.key];
					if (done != buildStepLength *
					    buildSteps)
					{
						buildingDetails ~= format
						    (`, %d%% built`,
						    done * 100L /
						    (buildStepLength *
						    buildSteps));
					}
					backgroundColorBuilding = mixColor
					    (buildings[buildId].loColor,
					    buildings[buildId].hiColor,
					    0, done, buildStepLength *
					    buildSteps).toColorInt;
				}
				string whiteFont;
				immutable int colorThreshold = 0x80;
				if (buildId != 0 &&
				    buildings[buildId].loColor.all !(c =>
				    c < colorThreshold))
				{
					whiteFont ~= `;color:#FFFFFF`;
					whiteFont ~= `;border-color:#000000`;
				}
				file.writefln (`<td style="text-align:left;` ~
				    `background-color:#%06X%s">%s</td>`,
				    backgroundColorBuilding, whiteFont,
				    buildingDetails);
				file.writeln (`</tr>`);
			}
			file.writeln (`</tbody>`);
			file.writeln (`</table>`);
			file.writeln (`<script src="auction.js"></script>`);
		}
		else
		{
			assert (false);
		}

		file.writefln (`<p><a href="..">Back to main page</a></p>`);
		file.writeln (`</body>`);
		file.writeln (`</html>`);
	}

	void doHtmlBuildings ()
	{
		auto title = "buildings";

		auto file = File (title ~ ".html", "wt");
		writeHtmlHeader (file, title);
		writeCoordRow (file);

		auto completed = new int [buildings.length];
		auto inProgress = new int [buildings.length];
		foreach (row; minRow..maxRow + 1)
		{
			file.writeln (`<tr>`);
			file.writeln (`<td class="coord">`, row, `</td>`);
			foreach (col; minCol..maxCol + 1)
			{
				auto pos = Coord (row, col);
				if (pos !in locations)
				{
					assert (false);
				}
				auto owner = locations[pos].owner.text;
				auto backgroundColor = 0xEEEEEE;
				auto sign = "&nbsp;";
				if (owner != "")
				{
					backgroundColor = 0xBBBBBB;
				}
				auto hoverText = toCoordString (pos);
				auto buildId =
				    locations[pos].building.build_id;
				if (buildId != 0)
				{
					hoverText ~= `&#10;` ~
					    buildings[buildId].name;
					auto done = buildingDone[pos];
					if (done == buildStepLength *
					    buildSteps)
					{
						sign = buildings[buildId].sign;
						completed[buildId] += 1;
					}
					else
					{
						hoverText ~= format
						    (`&#10;progress: %s of %s`,
						    done, buildStepLength *
						    buildSteps);
						inProgress[buildId] += 1;
					}
					backgroundColor = mixColor
					    (buildings[buildId].loColor,
					    buildings[buildId].hiColor,
					    0, done, buildStepLength *
					    buildSteps).toColorInt;
				}
				if (pos == Coord (0, 0))
				{
					hoverText ~= `&#10;Government`;
					backgroundColor = 0xBB88FF;
				}
				if (owner != "")
				{
					hoverText ~= `&#10;owner: ` ~ owner;
				}
				string whiteFont;
				immutable int colorThreshold = 0x80;
				if (buildId != 0 &&
				    buildings[buildId].loColor.all !(c =>
				    c < colorThreshold))
				{
					whiteFont ~= `;color:#FFFFFF`;
					whiteFont ~= `;border-color:#000000`;
				}
				file.writefln (`<td class="plot" ` ~
				    `style="background-color:#%06X%s" ` ~
				    `title="%s">%s</td>`,
				    backgroundColor, whiteFont,
				    hoverText, sign);
			}
			file.writeln (`<td class="coord">`, row, `</td>`);
			file.writeln (`</tr>`);
		}
		writeCoordRow (file);
		file.writeln (`</tbody>`);
		file.writeln (`</table>`);
		file.writefln (`<p>Generated on %s (UTC).</p>`, nowString);
		file.writeln (`<p>Classification by production: ` ~
		    `M = Material, R = Resource, ` ~
		    `T = Tools and Transport.</p>`);
		file.writefln (`<p>Tip: hover the mouse over a plot ` ~
		    `to see details.</p>`);

		file.writefln (`<h2>Building types:</h2>`);
		file.writeln (`<table border="1px" padding="2px">`);
		file.writeln (`<tbody>`);

		file.writeln (`<tr>`);
		file.writefln (`<th class="plot" ` ~
		    `width="16px">&nbsp;</th>`);
		file.writefln (`<th>Building type</th>`);
		file.writefln (`<th>Completed</th>`);
		file.writefln (`<th>In progress</th>`);
		file.writeln (`</tr>`);

		foreach (ref building; buildings)
		{
			if (building == BuildingPlan.init)
			{
				continue;
			}

			auto backgroundColor = building.hiColor.toColorInt;
			string whiteFont;
			if (building.loColor.all !(c => c < colorThreshold))
			{
				whiteFont ~= `;color:#FFFFFF`;
				whiteFont ~= `;border-color:#000000`;
			}

			file.writeln (`<tr>`);
			file.writefln (`<td class="plot" width="16px" ` ~
			    `style="text-align:center;` ~
			    `background-color:#%06X%s">%s</td>`,
			    backgroundColor, whiteFont, building.sign);
			file.writeln (`<td style="text-align:left">`,
			    building.name, `</td>`);
			file.writeln (`<td style="text-align:right">`,
			    completed[building.id.to !(int)], `</td>`);
			file.writeln (`<td style="text-align:right">`,
			    inProgress[building.id.to !(int)], `</td>`);
			file.writeln (`</tr>`);
		}

		file.writeln (`<tr>`);
		file.writefln (`<td class="plot" width="16px">` ~
		    `&nbsp;</td>`);
		file.writeln (`<td style="font-weight:bold;` ~
		    `text-align:left">Total</td>`);
		file.writeln (`<td style="text-align:right">`,
		    completed.sum, `</td>`);
		file.writeln (`<td style="text-align:right">`,
		    inProgress.sum, `</td>`);
		file.writeln (`</tr>`);

		file.writeln (`</tbody>`);
		file.writeln (`</table>`);
		file.writefln (`<p><a href="..">Back to main page</a></p>`);
		file.writeln (`</body>`);
		file.writeln (`</html>`);
	}

	doHtml (resTemplate[0..1]);
	doHtml (resTemplate[1..2]);
	doHtml (resTemplate[2..3]);
	doHtml (resTemplate[3..4]);
	doHtml (resTemplate[4..5]);
	doHtml (resTemplate[5..6]);
	doHtml (resTemplate[6..7]);
	doHtml (resTemplate[1..3] ~ resTemplate[6]);
	doHtml (resTemplate[3..6]);
	doHtml (resTemplate[0..7]);
	doHtmlWorker (resTemplate[7..8]);
	doHtmlRent ("rent", RentMapType.simple);
	doHtmlRent ("rent-days", RentMapType.daysLeft);
	doHtmlRent ("auction", RentMapType.auction);
	doHtmlBuildings ();

	return 0;
}
