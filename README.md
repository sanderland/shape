# SHAPE: Shape Habits Analysis and Personalized Evaluation

SHAPE is a Go app with AI feedback, designed to help you identify and correct common mistakes based on your skill level.

![SHAPE Application Screenshot](assets/screenshot.png)

## Quick Start

Run the application directly using `uvx`:

```bash
uvx goshape
```

The first time you run this, `uv` will automatically download the package, create a virtual environment, and install all dependencies.

When the application starts for the first time, it will also check for the required KataGo models in `~/.katrain/`. If they are not found, a dialog will appear to guide you through downloading them.

## Features

- **Personalized Mistake Analysis**: The AI feedback is tailored to your rank, flagging mistakes that are relevant to your level.
- **Interactive Board**: A clean, responsive Go board with heatmap visualizations.
- **Detailed AI Feedback**: An analysis tab shows the score graph and KataGo's top move considerations.
- **Configurable Opponent**: Play against an AI opponent with customizable rank, style, and behavior.
- **SGF Support**: Save and load games, or copy/paste SGF data from the clipboard.

## How to Use

The main window is divided into the board on the left and a control panel with three tabs on the right.

### Board Controls

Underneath the board, you will find the main game controls:
- **Pass**: Pass your turn.
- **Undo**: Go back one move. This button is only active when there are moves to undo.
- **Redo**: Go forward one move. This button is only active when you have undone moves.
- **AI Move**: Force the AI to make a move, even if it is your turn.

### The "Play" Tab

This is the main control center for your game.

- **Game Control**:
  - **Play as**: Choose to play as Black or White.
  - **Opponent Controls**: Force the AI to move or enable **Auto-play** for the AI to play automatically when it's its turn.
- **Player Settings**:
  - **Current Rank**: Your current Go skill level. This is used to determine which mistakes are typical for you.
  - **Target Rank**: The skill level you want to aim for. Mistakes common at this level won't be flagged.
  - **Opponent**: The type and level of the AI opponent. This supports modern, pre-AlphaGo style, and historical professional styles.
- **Heatmap**: Visualize the AI's preferred moves for different player models (Current Rank, Target Rank, AI, and Opponent). You can select multiple heatmaps to get a blended view.
- **Info Panel**: A collapsible panel (shortcut: `Ctrl+0`) that shows detailed statistics about the last move.

### The "AI Analysis" Tab

This tab provides feedback from the AI.
- **Score Graph**: A graph showing the score progression over the course of the game. The Y-axis is centered at 0, with a dashed line indicating an even game.
- **Top Moves**: A table showing KataGo's top 5 recommended moves for the current position, including win rate, score lead, and visits.
- **Deeper AI Analysis**: A button to request a much deeper analysis (more visits) for the current position.

### The "Settings" Tab

This tab allows you to fine-tune the AI's behavior.

- **Policy Sampling**: These settings affect the AI's move selection and the heatmap visualization. Tooltips are provided in the app for detailed explanations.
  - **Top K**: Considers only the top K moves.
  - **Top P**: Considers moves from the smallest set whose cumulative probability exceeds P.
  - **Min P**: Considers only moves with a probability of at least P times the probability of the best move.
- **Analysis Settings**:
  - **Visits**: The number of playouts the AI will perform for its analysis. Higher values lead to stronger play but require more processing time.
- **Mistake Feedback**: These settings determine when the game will automatically halt. The game halts if the mistake size is above the configured threshold **AND** either of the probability conditions are met.

Keep in mind that the techniques used are more likely to be helpful up to low-dan levels, and may not be as effective at high-dan or professional levels.

