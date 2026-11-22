const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('claimCheck', {
  init: () => ipcRenderer.invoke('review:init'),
  models: () => ipcRenderer.invoke('review:models'),
  saveSettings: settings => ipcRenderer.invoke('review:settings', settings),
  clipboard: () => ipcRenderer.invoke('review:clipboard'),
  copyEvidence: text => ipcRenderer.invoke('review:copy-evidence', text),
  onClipboard: callback => {
    const listener = (_event, text) => callback(text);
    ipcRenderer.on('review:clipboard-preview', listener);
    return () => ipcRenderer.removeListener('review:clipboard-preview', listener);
  },
  check: input => ipcRenderer.invoke('review:check', input),
  evidence: input => ipcRenderer.invoke('review:evidence', input),
  cancel: () => ipcRenderer.invoke('review:cancel'),
  search: query => ipcRenderer.invoke('review:search', query),
  openSource: url => ipcRenderer.invoke('review:open-source', url)
});
