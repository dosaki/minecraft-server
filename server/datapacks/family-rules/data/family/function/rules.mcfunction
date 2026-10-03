# Server gamerules, applied by the game every time the world loads (and on /reload).
# 26.x names rules by registry id, e.g. players_sleeping_percentage, not playersSleepingPercentage.

# Skip the night once half the overworld players are asleep (vanilla rounds up: 3 online -> 2).
gamerule players_sleeping_percentage 50
