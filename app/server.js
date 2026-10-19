'use strict';

const express = require('express');

const app = express();
const port = Number(process.env.PORT) || 3000;

app.get('/', (_req, res) => {
  res.type('text/plain').send('Hello World!');
});

app.listen(port, '0.0.0.0', () => {
  console.log(`Express server listening on port ${port}`);
});
