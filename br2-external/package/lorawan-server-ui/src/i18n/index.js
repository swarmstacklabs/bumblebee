import { MESSAGES } from './messages';

const DEFAULT_LOCALE = 'en';
const FALLBACK_MESSAGES = MESSAGES[DEFAULT_LOCALE] || {};

const normalizeLocale = (value) => {
  if (!value) {
    return DEFAULT_LOCALE;
  }
  const short = String(value).trim().toLowerCase().split('-')[0];
  return MESSAGES[short] ? short : DEFAULT_LOCALE;
};

export const getLocale = () => {
  if (typeof window === 'undefined') {
    return DEFAULT_LOCALE;
  }
  const stored = window.localStorage?.getItem('ui.locale');
  if (stored) {
    return normalizeLocale(stored);
  }
  return normalizeLocale(window.navigator?.language || document.documentElement?.lang);
};

export const setLocale = (value) => {
  const locale = normalizeLocale(value);
  if (typeof window !== 'undefined') {
    window.localStorage?.setItem('ui.locale', locale);
  }
  return locale;
};

export const t = (key, fallback = '') => {
  const locale = getLocale();
  const localeMessages = MESSAGES[locale] || {};
  return localeMessages[key] || FALLBACK_MESSAGES[key] || fallback || key;
};
