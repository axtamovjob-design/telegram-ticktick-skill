import argparse
import asyncio
import json
import os
from pathlib import Path

from telethon import TelegramClient
from telethon.errors import SessionPasswordNeededError
from telethon.sessions import StringSession


DATA_DIR = Path(os.environ.get('CODEX_TELEGRAM_DATA_DIR') or Path(os.environ['LOCALAPPDATA']) / 'CodexTelegram')
CONFIG = DATA_DIR / 'api.json'
SESSION = DATA_DIR / 'account.token'


def request_api_credentials():
    import re
    import tkinter as tk
    from tkinter import messagebox, simpledialog

    window = tk.Tk()
    window.withdraw()
    try:
        while True:
            credentials = simpledialog.askstring(
                'Telegram API credentials', 'Paste API ID and hash as ID:HASH', show='*', parent=window
            )
            if credentials is None:
                raise SystemExit('Setup cancelled.')
            match = re.fullmatch(r'([1-9][0-9]*):([0-9a-fA-F]{32})', credentials.strip())
            if match:
                return {'api_id': int(match[1]), 'api_hash': match[2]}
            messagebox.showerror('Telegram API', 'Use ID:HASH with a 32-character hex hash.', parent=window)
    finally:
        window.destroy()

async def scan_qr(client):
    import tkinter as tk
    from tkinter import simpledialog

    import qrcode

    window = tk.Tk()
    window.title('Telegram API | QR login')
    tk.Label(window, text='Telegram: Settings → Devices → Link Desktop Device').pack(padx=16, pady=8)
    image_label = tk.Label(window)
    image_label.pack()
    closed = asyncio.Event()
    window.protocol('WM_DELETE_WINDOW', closed.set)
    try:
        qr = await client.qr_login()
        while not closed.is_set():
            code = qrcode.QRCode()
            code.add_data(qr.url)
            matrix = code.get_matrix()
            rows = ['{' + ' '.join('black' if cell else 'white' for cell in row) + '}' for row in matrix]
            image = tk.PhotoImage(width=len(matrix), height=len(matrix))
            image.put(' '.join(rows))
            image = image.zoom(8)
            image_label.configure(image=image)
            pending = asyncio.create_task(qr.wait())
            try:
                while not pending.done() and not closed.is_set():
                    window.update()
                    await asyncio.sleep(0.05)
                if closed.is_set():
                    raise SystemExit('QR login cancelled.')
                return await pending
            except TimeoutError:
                await qr.recreate()
            except SessionPasswordNeededError:
                password = simpledialog.askstring('Telegram 2FA', 'Telegram password', show='*', parent=window)
                if password is None:
                    raise SystemExit('QR login cancelled.')
                return await client.sign_in(password=password)
            finally:
                if not pending.done():
                    pending.cancel()
                    await asyncio.gather(pending, return_exceptions=True)
    finally:
        window.destroy()


async def connect(login):
    if CONFIG.exists():
        api = json.loads(CONFIG.read_text(encoding='utf-8'))
    else:
        api = None
    reset_test_credentials = api is None or api['api_id'] == 17349
    if reset_test_credentials and not login:
        raise SystemExit('Run telegram_access.py login first.')
    if reset_test_credentials:
        api = request_api_credentials()

    if not login and not SESSION.exists():
        raise SystemExit('Run telegram_access.py login first.')
    saved_session = SESSION.read_text(encoding='ascii') if SESSION.exists() and not reset_test_credentials else None
    session = StringSession(saved_session)
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    client = TelegramClient(session, **api, device_model='Codex Python', receive_updates=login)
    try:
        await client.connect()
        if login and not await client.get_me():
            await scan_qr(client)

        account = await client.get_me()
        if account is None or account.bot:
            raise SystemExit('No authorized personal Telegram account. Run login first.')
        if login:
            temporary_session = SESSION.with_suffix('.tmp')
            temporary_session.write_text(session.save(), encoding='ascii')
            temporary_session.replace(SESSION)
            CONFIG.write_text(json.dumps(api), encoding='utf-8')
        username = f' (@{account.username})' if account.username else ''
        print(f'Telegram account verified: ID {account.id}{username}')
    finally:
        await client.disconnect()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='Sign in and verify a Telegram API session.')
    parser.add_argument('action', choices=['login', 'check'])
    args = parser.parse_args()
    asyncio.run(connect(args.action == 'login'))

