import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import en from './en.json';
import ar from './ar.json';

export type Lang = 'en' | 'ar';

const saved = (typeof localStorage !== 'undefined' && localStorage.getItem('lang')) as Lang | null;

void i18n.use(initReactI18next).init({
  resources: { en: { translation: en }, ar: { translation: ar } },
  lng: saved ?? 'en',
  fallbackLng: 'en',
  interpolation: { escapeValue: false },
});

export function applyDir(lang: string) {
  const dir = lang === 'ar' ? 'rtl' : 'ltr';
  document.documentElement.setAttribute('lang', lang);
  document.documentElement.setAttribute('dir', dir);
}

applyDir(i18n.language);
i18n.on('languageChanged', (lng) => {
  applyDir(lng);
  localStorage.setItem('lang', lng);
});

export default i18n;

