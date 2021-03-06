// Author: Ivan Kazmenko (gassa@mail.ru)
module refresh_logs_buy;
import std.algorithm;
import std.conv;
import std.datetime;
import std.digest.sha;
import std.format;
import std.json;
import std.net.curl;
import std.range;
import std.stdio;
import std.string;
import std.traits;
import std.typecons;

import prospectorsc_abi;
import transaction;

auto getWithData (Conn) (string url, string [string] data, Conn conn)
{
	return get (url ~ "?" ~ data.byKeyValue.map !(line =>
	    line.key ~ "=" ~ line.value).join ("&"), conn);
}

string maybeStr () (const auto ref JSONValue value)
{
	if (value.isNull)
	{
		return "";
	}
	return value.str;
}

bool isResource (int id)
{
	return 1 <= id && id <= 6 || id == 31;
}

bool isTool (int id)
{
	return 17 <= id && id <= 24;
}

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

alias hexStringToBinary = str => str.chunks (2).map !(value =>
    to !(ubyte) (value, 16)).array;

alias ItemPlan = Tuple !(long, q{id}, string, q{name}, int, q{weight});

ItemPlan [] itemList;
short [string] itemIdByName;

void prepare ()
{
	itemList = [ItemPlan.init] ~
	    File ("items.txt").byLineCopy.map !(split)
	    .map !(t => ItemPlan (t[0].to !(long), t[1], t[2].to !(int)))
	    .array;

	foreach (ref item; itemList)
	{
		itemIdByName[item.name] = item.id.to !(short);
	}
}

struct Coord
{
	int row;
	int col;

	this (long id)
	{
		row = cast (short) (id & 0xFFFF);
		col = cast (short) (id >> 16);
	}

	static string numString (int value)
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

	string toString () const
	{
		// as in the game: first column, then row
		return numString (col) ~ "/" ~ numString (row);
	}
}

void updateLogGeneric (alias doSpecific)
    (string endPoint, string queryForm, string query)
{
	auto dfuseToken = File ("../dfuse.token").readln.strip;
	auto sha256 = query.sha256Of.format !("%(%02x%)");

	immutable string cursorFileName = sha256 ~ ".cursor";
	string wideCursor;
	try
	{
		wideCursor = File (cursorFileName).readln.strip;
	}
	catch (Exception e)
	{
		wideCursor = "";
	}

	auto connection = HTTP ();
	connection.addRequestHeader ("Authorization", "Bearer " ~ dfuseToken);
	auto logFile = File (sha256 ~ ".log", "ab");
	while (true)
	{
		auto filledQuery = format (queryForm, query, wideCursor);
		writeln ("updating ", query, ", cursor = ", wideCursor);
		auto raw = post (endPoint, filledQuery, connection);
		auto cur = raw.parseJSON["data"]["searchTransactionsForward"];
		auto newCursor = cur["cursor"].maybeStr;
		if (newCursor == "")
		{
			writeln (query, " update complete");
			break;
		}
		wideCursor = newCursor;

		string [] res;
		foreach (const ref result; cur["results"].array)
		{
			auto curCursor = result["cursor"].maybeStr;
			if (result["trace"]["receipt"]["status"].maybeStr !=
			    "EXECUTED")
			{
				assert (false);
			}

			auto ts1 = result["trace"]["block"]["timestamp"]
			    .maybeStr;
			auto ts2 = SysTime.fromISOExtString (ts1, UTC ());
			auto ts3 = ts2.toSimpleString;
			auto timestamp = ts3[0..20];

			doSpecific (res, result["trace"],
			    timestamp, curCursor);
		}

		foreach (const ref line; res)
		{
			logFile.writeln (line);
			logFile.flush ();
		}
		File (cursorFileName, "wb").writeln (wideCursor);
	}
}
