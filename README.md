# Sightline

A SwiftUI geospatial discovery prototype for iOS. Point the phone down a street and Sightline floats bubbles over the places ahead of you, ranks them by where you are actually looking, hides the ones a building is in the way of, and can walk you to the one you pick with a small per-place AI guide on tap.

Built on ARKit + ARCore Geospatial for pose and occlusion geometry, Google Places API for place data, and MapKit for walking routes and the mini-map. Uses Gemini 3.5 Flash via Gemini API for the AI agent.

## Screenshots

| Street view | Landmark lock-on | AI guide |
| :---: | :---: | :---: |
| <img src="Images/street.PNG" width="260" alt="AR street view with nearby place bubbles, a transit stop label, and the mini-map" /> | <img src="Images/landmark.PNG" width="260" alt="A single landmark bubble anchored on Canada's Wonderland across the road" /> | <img src="Images/assistant.PNG" width="260" alt="The per-place AI guide sheet answering a question about the landmark" /> |

- **Street view** — bubbles float over the places ahead, ranked by view direction, with distance and rating.
- **Landmark lock-on** — a bubble stays anchored to the landmark as you move, with a transit chip for the nearest stop.
- **AI guide** — tap a place to open a small grounded AI chat about it.
