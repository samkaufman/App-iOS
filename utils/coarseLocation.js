import {GetStoreData} from './asyncStorage';
import {GET_QUERY_SIZE_URL} from './endpoints';
import {QUERY_SIZE_LIMIT, PRECISION_LIMIT} from './constants';

export function getLatestCoarseLocation(isReporting = false) {
  return getLatestLocation().then(location => {
    const {latitude: lat, longitude: lon} = location;
    const coarsLocation = getCoarseLocation(lat, lon, isReporting);
    return coarsLocation;
  });
}

function getLatestLocation() {
  return GetStoreData('LOCATION_DATA').then(data => {
    const locations = JSON.parse(data);
    return locations[locations.length - 1];
  });
}

function getCoarseLocation(lat, lon, isReporting) {
  const bestPrecision = PRECISION_LIMIT; //corresponds to 1 / 16 degree ~ 7 km
  const initialPrecision = isReporting ? bestPrecision : 0; // 0corresponds to 1 degrees ~ 111 km

  let precision = initialPrecision;
  let coarseLat = round(lat, precision);
  let coarseLon = round(lon, precision);

  for (; precision < bestPrecision; ++precision) {
    if (canWeAfford(coarseLat, coarseLon, precision)) {
      break;
    }
    coarseLat = round(lat, precision);
    coarseLon = round(lon, precision);
  }

  return {
    latitudePrefix: coarseLat,
    longitudePrefix: coarseLon,
    precision,
  };
}

async function canWeAfford(lat, lon, precision) {
  let querySize = await fetchQuerySize(lat, lon, precision);
  return querySize <= QUERY_SIZE_LIMIT ? true : false;
}

function fetchQuerySize(lat, lon, precision) {
  const url = `${GET_QUERY_SIZE_URL}?lat=${lat}&lon=${lon}&precision=${precision}&lastTimestamp=0`;

  return fetch(url, {
    headers: {
      'Content-Type': 'application/json',
      'Accept': 'application/json'
    },
  })
    .then(response => {
      return response.json();
    })
    .then(data => {
      const {sizeOfQueryResponse} = data;
      return sizeOfQueryResponse;
    })
    .catch(err => {
      console.error(err);
    });
}

function round(d, precision) {
  return (
    parseFloat(parseInt(d * Math.pow(2, precision))) / Math.pow(2, precision)
  );
}