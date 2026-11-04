import {highlightSource} from './code_highlighter.js'
self.addEventListener('message', async ({data}) => {
  const {generation, node, revision, source, language, theme} = data
  try {
    const result = await highlightSource(source, language, theme)
    self.postMessage({generation, node, revision, ...result})
  } catch (error) {
    self.postMessage({generation, node, revision, error: `Highlighting unavailable: ${error.message}`})
  }
})
