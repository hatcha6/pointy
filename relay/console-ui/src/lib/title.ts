// The tab title is two things: the page, and how many transfers wait. Each is
// set by its own part of the app; the title is always both.

let page = "دفتر — لوحة التشغيل";
let waiting = 0;

function render() {
  document.title = (waiting ? `(${waiting}) ` : "") + page;
}

export function setPageTitle(title: string) {
  page = title;
  render();
}

export function setTitleCount(count: number) {
  waiting = count;
  render();
}
