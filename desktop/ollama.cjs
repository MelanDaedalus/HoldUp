const http = require('node:http');

const localName = /^(?:[\w][\w.-]*(?::\d{1,5})?\/)?(?:[\w][\w.-]*\/)?[\w][\w.-]*:[\w][\w.-]*$/;

function ordinaryName(name) {
  return typeof name === 'string' && name.length <= 160 && localName.test(name) &&
    !/[:/-]cloud$/i.test(name) && !name.toLowerCase().startsWith('cloud/');
}

function remote(entry) {
  return Boolean(entry?.remote_host || entry?.remote_model || entry?.remoteHost || entry?.remoteModel);
}

function loopbackRequest(port = 11434) {
  return (path, body, timeout, signal) => new Promise((resolve, reject) => {
    const payload = body === undefined ? undefined : JSON.stringify(body);
    const deadline = AbortSignal.timeout(timeout);
    const request = http.request({
      hostname: '127.0.0.1', port, path, agent: false,
      method: payload === undefined ? 'GET' : 'POST',
      signal: signal ? AbortSignal.any([deadline, signal]) : deadline,
      headers: payload === undefined ? undefined : {
        'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload)
      }
    }, response => {
      if (response.statusCode < 200 || response.statusCode >= 300) {
        response.resume();
        return reject(new Error(`Ollama returned HTTP ${response.statusCode}.`));
      }
      const chunks = [];
      let bytes = 0;
      response.on('error', reject);
      response.on('data', chunk => {
        bytes += chunk.length;
        if (bytes > 8 * 1024 * 1024) request.destroy(new Error('Ollama response exceeded the size limit.'));
        else chunks.push(chunk);
      });
      response.on('end', () => {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        } catch {
          reject(new Error('Ollama returned invalid JSON.'));
        }
      });
    });
    request.on('error', reject);
    request.end(payload);
  });
}

class LocalOllama {
  constructor(request = loopbackRequest()) {
    this.request = request;
  }

  async verifyCloud(signal) {
    let status;
    try {
      status = await this.request('/api/status', undefined, 3500, signal);
    } catch (error) {
      signal?.throwIfAborted();
      if (error.code === 'ECONNREFUSED') throw new Error('Start Ollama on this computer, then refresh the model list.');
      throw new Error('Could not verify Ollama’s local-only setting. Start or update Ollama and retry.');
    }
    if (status?.cloud?.disabled !== true) {
      throw new Error('Ollama cloud features are enabled. Disable them in Ollama, restart it, and refresh the model list.');
    }
  }

  async models(signal) {
    await this.verifyCloud(signal);
    const result = await this.request('/api/tags', undefined, 8000, signal);
    if (!Array.isArray(result?.models)) throw new Error('Ollama returned an invalid model list.');
    const installed = new Set();
    for (const model of result.models) {
      if (ordinaryName(model?.name) && model.name === model.model && !remote(model) &&
          (!Array.isArray(model.capabilities) || model.capabilities.includes('completion'))) installed.add(model.name);
    }
    return [...installed].sort();
  }

  async generate(model, input, system, schema, signal) {
    if (!ordinaryName(model)) throw new Error('Choose an installed local text model.');
    await this.verifyCloud(signal);
    const name = `${model}:local`;
    try {
      const metadata = await this.request('/api/show', { model: name }, 15_000, signal);
      if (remote(metadata) || !metadata.capabilities?.includes('completion') ||
          !['gguf', 'safetensors'].includes(metadata.details?.format) ||
          !metadata.model_info?.['general.architecture']) throw new Error('Invalid model metadata.');
    } catch {
      signal?.throwIfAborted();
      throw new Error('Could not verify this as an installed local text model. Refresh the list or choose another model.');
    }

    const options = { num_ctx: 8192, num_predict: 1600, temperature: 0.1 };
    const base = { model: name, stream: false, keep_alive: '2m', options };
    const loaded = await this.request('/api/generate', base, 180_000, signal);
    if (loaded?.done !== true || loaded.done_reason !== 'load' || loaded.model !== name || remote(loaded)) {
      throw new Error('Ollama could not load the verified local model.');
    }
    await this.verifyCloud(signal);
    const prompt = JSON.stringify(input).replaceAll('<', '\\u003c');
    const result = await this.request('/api/generate', {
      ...base, system, prompt, format: schema, think: false, truncate: false, shift: false
    }, 180_000, signal);
    if (result?.done !== true || result.done_reason !== 'stop' || result.model !== name ||
        remote(result) || typeof result.response !== 'string' || result.response.length > 32_000) {
      throw new Error('Ollama did not finish this review. Try again or choose another model.');
    }
    try {
      return JSON.parse(result.response);
    } catch {
      throw new Error('The model returned an invalid review. Try again.');
    }
  }
}

module.exports = { LocalOllama, loopbackRequest, ordinaryName };
