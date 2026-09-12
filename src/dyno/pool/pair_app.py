"""Small coordinator pairing window; reusable before integration into Pools."""
import json
from pathlib import Path
import queue
import threading
import tkinter as tk
from tkinter import messagebox, ttk

from .discovery import discover, local_interfaces, peer_on_lan
from .pairing import new_identity, pair, save_pair


class PairApp:
    def __init__(self, root):
        self.root, self.events = root, queue.Queue()
        self.devices, self.busy, self.closed = [], False, False
        root.title('Dyno · Nearby workers')
        root.geometry('780x510')
        panel = ttk.Frame(root, padding=20)
        panel.pack(fill='both', expand=True)
        ttk.Label(panel, text='Connect to your pool', font=('', 20, 'bold')).pack(anchor='w')
        ttk.Label(panel, text='Open Dyno Worker on another computer on the same local network.').pack(anchor='w', pady=8)
        self.status = tk.StringVar(value='Searching for nearby workers…')
        ttk.Label(panel, textvariable=self.status, wraplength=720).pack(anchor='w', pady=8)
        self.list = tk.Listbox(panel, height=7, exportselection=False)
        self.list.pack(fill='both', expand=True)
        buttons = ttk.Frame(panel)
        buttons.pack(fill='x', pady=12)
        self.scan_button = ttk.Button(buttons, text='Refresh', command=self.scan)
        self.scan_button.pack(side='left')
        self.pair_button = ttk.Button(buttons, text='Pair selected worker', command=self.connect)
        self.pair_button.pack(side='left', padx=8)
        self.details = tk.StringVar()
        ttk.Label(panel, textvariable=self.details, wraplength=720).pack(anchor='w')
        root.protocol('WM_DELETE_WINDOW', self.close)
        root.after(100, self.poll)
        self.scan()

    def run(self, task):
        if self.busy:
            return
        self.busy = True
        self.scan_button.configure(state='disabled')
        self.pair_button.configure(state='disabled')
        def work():
            try:
                task()
            except Exception as exc:
                self.events.put(('status', str(exc)))
            finally:
                self.events.put(('done', None))
        threading.Thread(target=work, daemon=True).start()

    def scan(self):
        self.status.set('Searching for nearby workers…')
        self.run(lambda: self.events.put(('devices', discover(local_interfaces()))))

    def confirm(self, code):
        event, answer = threading.Event(), []
        self.events.put(('confirm', (code, event, answer)))
        if not event.wait(110):
            return False
        return bool(answer and answer[0])

    def connect(self):
        selected = self.list.curselection()
        if not selected:
            return
        device = dict(self.devices[selected[0]])
        self.status.set('Connecting. Compare the verification code on both computers.')
        def task():
            if not any(i['address'] == device['local_address'] and peer_on_lan(device['address'], i)
                       for i in local_interfaces()):
                raise ValueError('LAN interface changed. Refresh discovery and try again.')
            # Never reuse an identity from a failed or unconfirmed attempt.
            directory, public = new_identity()
            try:
                result = pair(device['address'], device['port'], device['local_address'], public, self.confirm)
                record = save_pair(directory, device['address'], device['local_address'], result)
            except Exception:
                # Only files owned by this newly-created attempt can be removed.
                for name in ('identity', 'known_hosts', 'connection.json'):
                    (directory / name).unlink(missing_ok=True)
                directory.rmdir()
                raise
            self.events.put(('paired', (record, directory)))
        self.run(task)

    def poll(self):
        while not self.events.empty():
            kind, value = self.events.get_nowait()
            if kind == 'devices':
                self.devices = value
                self.list.delete(0, 'end')
                for d in value:
                    self.list.insert('end', f"{d['name']} · {d['gpu']}")
                self.status.set(f'{len(value)} nearby worker(s).' if value else
                    'No workers found. Enable discovery on the worker and check the LAN/firewall profile.')
            elif kind == 'confirm':
                code, event, answer = value
                answer.append(messagebox.askyesno('Verify both computers',
                    'Does the worker show this exact code?\n\n' + code +
                    '\n\nConfirm on both screens only if every group matches.', parent=self.root))
                event.set()
                self.status.set('Waiting for worker confirmation and Windows setup…')
            elif kind == 'paired':
                record, directory = value
                self.status.set('Paired. SSH identity and verified host key saved for this worker.')
                self.details.set('Connection saved to:\n' + str(directory / 'connection.json') +
                    '\nUse this connection in Pools, then choose your GGUF model and Test devices.')
            elif kind == 'status':
                self.status.set(value)
            elif kind == 'done':
                self.busy = False
                self.scan_button.configure(state='normal')
                self.pair_button.configure(state='normal')
        if not self.closed:
            self.root.after(100, self.poll)

    def close(self):
        if self.busy:
            messagebox.showinfo('Pairing in progress', 'Finish or reject the current pairing before closing.')
            return
        self.closed = True
        self.root.destroy()


def main():
    root = tk.Tk()
    PairApp(root)
    root.mainloop()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
