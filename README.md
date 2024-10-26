# SHAPE: Strategic Habits And Personalized Evaluation

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

- Current Rank: Your current Go skill level. For a quick start, just set this, and leave all other settings as default.
- Opponent Rank: The skill level of the AI opponent.
- Target Rank: The skill level you want to aim for.

The game will automatically halt when a typical mistake is made by you, allowing you to analyze, undo, or just continue.

Keep in mind that the techniques used are more likely to be helpful up to low-dan levels, and may not be helpful at all at high levels.


