import { parsePairingURL } from './probe.mjs';
import { connectPair } from './connection.mjs';
import { PhoneProbe } from './phone.mjs';

const byID = id => document.getElementById(id);
const action = byID('action');
const refresh = byID('refresh');
let config, connection, timeout, peerCheck, readinessTick, generation = 0;
const phone = new PhoneProbe();
const statusMessages = {
  connecting: 'Łączenie…', connected: 'Oczekiwanie na dane z Maca…',
  'peer-offline': 'Mac jest niedostępny — widzisz ostatni otrzymany podgląd',
  disconnected: 'Utracono połączenie — ponawianie…', closed: 'Połączenie wstrzymane',
  rejected: 'Połączenie odrzucone. Zeskanuj QR ponownie.',
  'invalid-message': 'Nie udało się zweryfikować wiadomości.',
};
const resultMessages = {
  idle: 'Wynik pojawi się po potwierdzeniu z Maca.', sending: 'Wysyłanie akcji…',
  accepted: 'Mac przyjął akcję. Oczekiwanie na wynik…', completed: 'Akcja wykonana i potwierdzona przez Maca.',
  rejected: 'Akcja odrzucona. Odśwież podgląd.',
  uncertain: 'Brak potwierdzenia wyniku. Sprawdź licznik wykonanych akcji po odświeżeniu.',
};
function controls() {
  byID('dot').classList.toggle('online', phone.hostAvailable);
  action.disabled = !phone.canAct;
  refresh.disabled = !phone.canRefresh;
  byID('result').textContent = resultMessages[phone.result];
  if (!phone.pending) clearTimeout(timeout);
  if (phone.state === 'connected' && phone.fresh && !phone.hostAvailable) {
    byID('status').textContent = 'Brak aktualnego potwierdzenia z Maca — odświeżanie…';
  }
}
function render(data) {
  if (data?.type !== 'snapshot' || typeof data.hostSession !== 'string' || !Array.isArray(data.lanes)) return;
  byID('status').textContent = 'Połączono z Makiem';
  byID('updated').textContent = `Ostatnia aktualizacja: ${new Date(data.generatedAt).toLocaleTimeString('pl-PL')}`;
  byID('ready-count').textContent = '1';
  const card = document.createElement('div');
  card.className = 'card';
  card.textContent = 'Mac jest gotowy';
  const detail = document.createElement('p');
  detail.textContent = 'Możesz sprawdzić wykonanie akcji z telefonu.';
  card.append(detail);
  byID('ready').replaceChildren(card);
  renderCount(data.executions);
  controls();
}
function renderCount(count) {
  if (!Number.isSafeInteger(count) || count < 0) return;
  byID('done-count').textContent = count ? '1' : '0';
  const result = document.createElement('p');
  result.className = count ? 'card' : 'empty';
  result.textContent = count ? `Potwierdzone wykonania na Macu: ${count}` : 'Brak wyników';
  byID('done').replaceChildren(result);
}
async function start() {
  if (!config || document.hidden) return;
  const current = ++generation;
  clearInterval(peerCheck); clearInterval(readinessTick);
  connection?.close();
  phone.transport('connecting');
  controls();
  try {
    const next = await connectPair({ ...config, role: 'phone',
      onState: state => {
        if (current !== generation) return;
        byID('status').textContent = statusMessages[state] ?? state;
        phone.transport(state);
        controls();
      },
      onOpen: client => client.send(phone.hello()),
      onPayload: async data => {
        if (current !== generation) return;
        if (data.type === 'host-ready') { await connection.send(phone.hello()); return; }
        const matching = data.id && data.id === phone.pending;
        const accepted = phone.receive(data);
        if (accepted === 'snapshot') render(data);
        if (matching && data.type === 'completed') renderCount(data.executions);
        controls();
      },
    });
    if (current !== generation || document.hidden) { next.close(); return; }
    connection = next;
    await next.ready;
    if (current !== generation) return;
    peerCheck = setInterval(() => {
      if (!phone.canRefresh || document.hidden) return;
      void connection.send(phone.hello()).catch(() => { phone.transport('disconnected'); controls(); });
    }, 25000);
    readinessTick = setInterval(controls, 1000);
  } catch {
    if (current !== generation) return;
    phone.transport('disconnected');
    controls();
    byID('status').textContent = 'Nie udało się połączyć. Sprawdź połączenie i zeskanuj QR ponownie.';
  }
}
action.addEventListener('click', async () => {
  const command = phone.beginCommand();
  if (!command) return;
  controls();
  timeout = setTimeout(() => { phone.expireCommand(); controls(); }, 10000);
  try { await connection.send(command); }
  catch { phone.expireCommand(); controls(); }
});
refresh.addEventListener('click', async () => {
  try { await connection.send(phone.hello()); }
  catch { phone.transport('disconnected'); controls(); }
});
document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    generation++;
    clearInterval(peerCheck); clearInterval(readinessTick);
    connection?.close();
    phone.transport('closed');
    controls();
    byID('status').textContent = 'Połączenie wstrzymane';
  } else void start();
});
if (location.hash) {
  try {
    config = parsePairingURL(location.href);
    history.replaceState(null, '', location.pathname);
    await start();
  } catch {
    history.replaceState(null, '', location.pathname);
    byID('status').textContent = 'Nieprawidłowy kod parowania. Zeskanuj QR ponownie.';
  }
}
