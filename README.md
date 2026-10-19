# WoWFFarm

A gathering helper for **World of Warcraft: Forever**.
Store herb and ore nodes, then let WoWFFarm guide you on an
endless farm route using Blizzard's built-in waypoint (world marker,
minimap and map pin).

## Features
- Node database per zone with automatic duplicate merging
- Farm run: auto-advances to the next unvisited node on arrival
- Skip empty nodes (5 min cooldown)
- Small movable farm panel with live distance, Skip and Stop buttons
- Active runs survive /reload and relog

## Commands
| Command | Description |
|---|---|
| `/fg add <name>` | Store a node at your position |
| `/fg list [name]` | List nodes in the current zone |
| `/fg next [name]` | Waypoint to the nearest node |
| `/fg run [name]` | Start a farm run |
| `/fg skip` | Mark current node empty, go to next |
| `/fg stop` | Stop the farm run |
| `/fg del` | Delete the node you stand at |
| `/fg stats` | Total stored nodes |

## Status
Early development, targeting the WoW Forever launch.