// One visual detail card shared by every graph and heatmap. The corresponding
// output in each chart exposes the same values to keyboard/screen-reader users.
let popup, owner;
const node=(tag,cls,text)=>{const n=document.createElement(tag);n.className=cls;n.textContent=text;return n;};
export function hideInspector(source) {
  if(source && source!==owner)return;
  if(popup)popup.hidden=true;
  owner=null;
}
export function showInspector(source, detail, anchor, kind='chart') {
  if(!popup){popup=node('div','inspector','');popup.setAttribute('aria-hidden','true');document.body.append(popup);}
  owner=source;popup.dataset.kind=kind;
  popup.replaceChildren(node('div','inspector-heading',detail.heading));
  for(const item of detail.rows.slice(0,8)){
    const row=node('div','inspector-row',''),label=node('span','inspector-label',item.label),value=node('strong','',item.value);
    if(item.color){const dot=node('i','inspector-dot','');dot.style.background=item.color;label.prepend(dot);}
    row.append(label,value);popup.append(row);
  }
  const caption=[detail.caption,detail.rows.length>8?`${detail.rows.length-8} more entries in the detail below.`:''].filter(Boolean).join(' ');
  if(caption)popup.append(node('div','inspector-caption',caption));
  popup.hidden=false;
  const gutter=10,gap=14,width=popup.offsetWidth,height=popup.offsetHeight;
  const left=anchor.x+gap+width<=innerWidth-gutter?anchor.x+gap:anchor.x-gap-width;
  popup.style.left=`${Math.max(gutter,Math.min(innerWidth-width-gutter,left))}px`;
  popup.style.top=`${Math.max(gutter,Math.min(innerHeight-height-gutter,anchor.y-height/2))}px`;
}
window.addEventListener('resize',()=>hideInspector());
document.addEventListener('scroll',()=>hideInspector(),true);
