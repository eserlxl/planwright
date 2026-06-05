# planwright Plan — js fixture

- [ ] Re-export clamp from the package entry point
      Mode: develop
      Rationale: util.clamp exists but index.js does not surface it to importers.
      Evidence: src/util.js exports clamp; src/index.js only consumes it locally.
      Surfaces: src/index.js, src/util.js
      Development: in index.js export { add, clamp } so require("calc") exposes both.
      Acceptance: requiring the package returns add and clamp.
      Verification: node src/index.js
