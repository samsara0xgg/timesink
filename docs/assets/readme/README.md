# README artwork

`timesink-poster.svg` is the editable source for `timesink-poster.png`.
The poster is an editorial feature overview, not an app screenshot or a simulated dashboard. Its claims refer to the source code on `main`; it includes no personal activity data.

Render with Node.js and Sharp:

```js
const sharp = require('sharp');
sharp('docs/assets/readme/timesink-poster.svg')
  .png()
  .toFile('docs/assets/readme/timesink-poster.png');
```

The artwork uses Avenir Next when available; install that font to reproduce the typography exactly.
