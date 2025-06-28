# SHAPE: Shape Habits Analysis and Personalized Evaluation

SHAPE is an app to play Go with AI feedback, specifically designed to point out typical bad habits for your current skill level.

This is an experimental project, and is unlikely to ever become very polished.

## Quick Start

Run the application directly using `uvx`:

```bash
uvx goshape
```

The first time you run this, `uv` will automatically download the package, create a virtual environment, and install all dependencies.

When the application starts for the first time, it will check for the required KataGo models in `~/.katrain/`. If they are not found, a dialog will appear to guide you through downloading them.

## Manual

The most important settings are:

- Current Rank: Your current Go skill level, which determines which mistakes are considered "typical" for your level.
- Target Rank: The skill level you want to aim for. Even if a move is a huge mistake, if it was a mistake still common at that level, it won't be considered relevant.
- Opponent: The type and level of the AI opponent. 
  - This supports modern, pre-alphago style, and historical professional style. 
  - Like the feedback, it is likely to be somewhat weaker than actual professionals or high-dan players.

The game will automatically halt when a typical mistake is made by you, allowing you to analyze, undo, or just continue.

Keep in mind that the techniques used are more likely to be helpful up to low-dan levels, and may not be helpful at all at high levels.

### Heatmap

The policy heatmap shows the probability of the top moves being made for your current rank, target rank, and AI.
Note that a move being probable does not mean it is a good move.
You can select multiple heatmaps to get a blended view, where size/number is the average probability, and the color is the average rank (current, target, AI).


## TODO list from Gemini

Based on a code review, here are some suggested areas for improvement:

### High Impact
- **User-Friendly Errors (`main.py`):** Show GUI dialogs for errors instead of crashing the application.

### Medium Impact
- **Refactor `GameNode` (`game_logic.py`):** Extract board state and rule logic into a separate `Board` class to simplify `GameNode` and improve modularity.

### Low Impact
- **Code Clarity (`game_logic.py`):** Improve code readability.

