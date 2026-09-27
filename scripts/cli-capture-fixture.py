#!/usr/bin/env python3
"""Synthetic scene for the private Xvfb capture acceptance test."""
import argparse
from pathlib import Path
import tkinter as tk

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ready-file', type=Path, required=True)
args = parser.parse_args()
window = tk.Tk()
window.title('Recall CLI synthetic capture fixture')
window.geometry('1280x800+0+0')
window.overrideredirect(True)
window.configure(background='white')
label = tk.Label(window, font=('DejaVu Sans', 42), bg='white', fg='black', padx=35, pady=100)
label.pack()


def update(counter=0):
    label.configure(text=f'Aurora launch is Tuesday\nRecall capture validation\nSynthetic scene {counter}')
    window.after(1500, lambda: update(counter + 1))


update()
window.update()
args.ready_file.write_text('ready\n')
window.after(240000, window.destroy)
window.mainloop()
