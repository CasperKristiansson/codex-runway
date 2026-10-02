// A single portal keeps menus outside the page scroller and inside the viewport.
// Focus stays on the combobox; activedescendant exposes keyboard exploration.
let active = null, sequence = 0;
export const dropdownIsOpen = () => active !== null;
export function closeDropdown() {
  if (!active) return;
  active.trigger.setAttribute('aria-expanded', 'false');
  active.trigger.removeAttribute('aria-activedescendant');
  active.menu.remove();
  active = null;
}
document.addEventListener('pointerdown', event => {
  if (active && !active.trigger.contains(event.target) && !active.menu.contains(event.target)) closeDropdown();
});
document.addEventListener('focusin', event => {
  if (active && !active.trigger.contains(event.target) && !active.menu.contains(event.target)) closeDropdown();
});
window.addEventListener('resize', closeDropdown);
document.addEventListener('scroll', event => {
  if (active && !active.menu.contains(event.target)) closeDropdown();
}, true);

export function createDropdown(name, options, value, onChange, key = name) {
  const id = `dropdown-${++sequence}`;
  const field = document.createElement('div'); field.className = 'select-field';
  const label = document.createElement('span'); label.className = 'select-label'; label.textContent = name;
  const trigger = document.createElement('button'); trigger.type = 'button'; trigger.className = 'dropdown-trigger';
  trigger.dataset.focusKey = key;
  trigger.setAttribute('role', 'combobox'); trigger.setAttribute('aria-label', name);
  trigger.setAttribute('aria-haspopup', 'listbox'); trigger.setAttribute('aria-expanded', 'false');
  trigger.setAttribute('aria-controls', id);
  const selected = Math.max(0, options.findIndex(([v]) => v === value));
  const text = document.createElement('span'); text.textContent = options[selected]?.[1] || 'Choose…';
  const chevron = document.createElement('span'); chevron.className = 'dropdown-chevron'; chevron.setAttribute('aria-hidden', 'true');
  trigger.append(text, chevron); field.append(label, trigger);
  let cursor = selected, prefix = '', typedAt = 0;
  function highlight(index, scroll = true) {
    cursor = index;
    for (const [i, option] of [...active.menu.children].entries()) option.classList.toggle('is-highlighted', i === cursor);
    trigger.setAttribute('aria-activedescendant', `${id}-${cursor}`);
    if (scroll) active.menu.children[cursor]?.scrollIntoView({block: 'nearest'});
  }
  function choose(index) {
    const next = options[index]?.[0]; closeDropdown(); trigger.focus({preventScroll: true});
    if (next !== undefined && next !== value) Promise.resolve().then(() => onChange(next));
  }
  function open() {
    if (trigger.disabled || !options.length) return;
    closeDropdown(); prefix = ''; cursor = selected;
    const menu = document.createElement('div'); menu.id = id; menu.className = 'dropdown-menu';
    menu.setAttribute('role', 'listbox'); menu.setAttribute('aria-label', `${name} options`);
    for (const [i, [, title]] of options.entries()) {
      const option = document.createElement('div'); option.id = `${id}-${i}`; option.className = 'dropdown-option';
      option.setAttribute('role', 'option'); option.setAttribute('aria-selected', String(i === selected));
      const titleNode = document.createElement('span'); titleNode.textContent = title;
      const check = document.createElement('span'); check.className = 'dropdown-check'; check.setAttribute('aria-hidden', 'true'); check.textContent = i === selected ? '✓' : '';
      option.append(titleNode, check);
      option.onpointermove = () => highlight(i, false);
      option.onpointerdown = event => event.preventDefault(); // Keep keyboard focus on the combobox.
      option.onclick = () => choose(i); menu.append(option);
    }
    document.body.append(menu); active = {trigger, menu};
    trigger.setAttribute('aria-expanded', 'true');
    const rect = trigger.getBoundingClientRect(), gutter = 10;
    menu.style.width = `${Math.min(Math.max(rect.width, 210), window.innerWidth - gutter * 2)}px`;
    menu.style.left = `${Math.max(gutter, Math.min(rect.left, window.innerWidth - menu.offsetWidth - gutter))}px`;
    const below = window.innerHeight - rect.bottom - gutter - 6, above = rect.top - gutter - 6;
    const upward = below < Math.min(menu.scrollHeight, 180) && above > below;
    menu.style.maxHeight = `${Math.min(300, Math.max(40, upward ? above : below))}px`;
    menu.style.top = `${upward ? rect.top - menu.offsetHeight - 6 : rect.bottom + 6}px`;
    highlight(selected);
  }
  trigger.onclick = () => active?.trigger === trigger ? closeDropdown() : open();
  trigger.onkeydown = event => {
    const opened = active?.trigger === trigger;
    if (event.key === 'Escape' && opened) {event.preventDefault(); event.stopPropagation(); closeDropdown(); return;}
    if (event.key === 'Tab') {if (opened) closeDropdown(); return;}
    if (['ArrowDown', 'ArrowUp', 'Home', 'End', 'Enter', ' '].includes(event.key)) {
      event.preventDefault();
      if (!opened) {open(); if (!active) return; if (event.key === 'Home') highlight(0); if (event.key === 'End') highlight(options.length - 1); return;}
      if (event.key === 'Enter' || event.key === ' ') {choose(cursor); return;}
      highlight(event.key === 'Home' ? 0 : event.key === 'End' ? options.length - 1 : (cursor + (event.key === 'ArrowDown' ? 1 : options.length - 1)) % options.length);
    } else if (event.key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey) {
      event.preventDefault(); if (!opened) open(); if (!active) return;
      const now = Date.now(), char = event.key.toLocaleLowerCase();
      prefix = now - typedAt > 700 ? char : prefix + char; typedAt = now;
      const search = [...prefix].every(c => c === char) ? char : prefix;
      const start = search.length > 1 ? 0 : 1;
      for (let step = start; step < options.length + start; step++) {
        const i = (cursor + step) % options.length;
        if (options[i][1].toLocaleLowerCase().startsWith(search)) {highlight(i); break;}
      }
    }
  };
  return field;
}
