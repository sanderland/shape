# SHAPE: Shape Habits Analysis and Personalized Evaluation

SHAPE is an app to play Go with AI feedback, specifically designed to point out typical bad habits for your current skill level.

This is an experimental project, and is unlikely to ever become very polished.

## Installation

* Run install.sh to download the models.
* Run `poetry shell` and then `poetry install` to install the app in a local Python environment.
  * Alternatively, run `pip install .` to install the app in your current Python environment.

## Usage

* Run `shape` to start the app, or use `python shape/main.py`

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


