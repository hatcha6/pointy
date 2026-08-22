import {ProductKey} from './ui/products';

export type Product = {
  id: string;
  name: string;
  price: number;
  art: ProductKey;
  barcode: string;
  stock: number;
};

/** The demo catalogue. Prices in Libyan dinar. */
export const CATALOG: Product[] = [
  {id: 'p1', name: 'مياه معدنية', price: 1.0, art: 'water', barcode: '6224000112', stock: 240},
  {id: 'p2', name: 'شيبس بالملح', price: 2.5, art: 'chips', barcode: '6224000129', stock: 86},
  {id: 'p3', name: 'شوكولاتة بالحليب', price: 5.5, art: 'chocolate', barcode: '6224000136', stock: 54},
  {id: 'p4', name: 'عصير برتقال', price: 6.0, art: 'juice', barcode: '6224000143', stock: 31},
  {id: 'p5', name: 'قهوة ساخنة', price: 7.0, art: 'coffee', barcode: '6224000150', stock: 0},
  {id: 'p6', name: 'حليب كامل الدسم', price: 4.75, art: 'milk', barcode: '6224000167', stock: 62},
  {id: 'p7', name: 'مناديل ورقية', price: 2.5, art: 'tissue', barcode: '6224000174', stock: 118},
  {id: 'p8', name: 'منظف ملابس', price: 12.0, art: 'detergent', barcode: '6224000181', stock: 9},
  {id: 'p9', name: 'خبز طازج', price: 1.5, art: 'bread', barcode: '6224000198', stock: 40},
  {id: 'p10', name: 'أرز بسمتي', price: 28.0, art: 'rice', barcode: '6224000204', stock: 17},
  {id: 'p11', name: 'شاي أحمر', price: 8.5, art: 'tea', barcode: '6224000211', stock: 73},
  {id: 'p12', name: 'بيض طازج', price: 19.0, art: 'eggs', barcode: '6224000228', stock: 22},
];

/** The nine tiles the POS catalogue shows without scrolling. */
export const GRID_IDS = ['p1', 'p2', 'p3', 'p4', 'p6', 'p7', 'p9', 'p11', 'p12'];

export const byId = (id: string) => CATALOG.find((p) => p.id === id)!;

export const CATEGORIES = ['الكل', 'مشروبات', 'أغذية', 'حلويات', 'منتجات منزلية'];

export type CartLine = {id: string; qty: number};

export const cartTotal = (lines: CartLine[]) =>
  lines.reduce((s, l) => s + byId(l.id).price * l.qty, 0);

export const cartCount = (lines: CartLine[]) => lines.reduce((s, l) => s + l.qty, 0);
